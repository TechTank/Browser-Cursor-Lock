#cs ----------------------------------------------------------------------------
Script Name: Browser Cursor Lock
Author: Brogan Scott Houston McIntyre
Version: 0.2.0
Date: 2025-02-18
License: MIT
#ce ----------------------------------------------------------------------------

#pragma compile(Out, "Browser Cursor Lock.exe")
#pragma compile(Icon, "icon.ico")

#include <GUIConstantsEx.au3>
#include <TrayConstants.au3>
#include <WindowsConstants.au3>
#include <WinAPI.au3>
#include <WinAPIRes.au3>
#include <WinAPISys.au3>
#include <Array.au3>
#include <Math.au3>
#include <GDIPlus.au3>

; ========== ========== ========== ========== ==========

Func _Singleton($sMutexName, $iFlag)
	Local $hMutex = DllCall("kernel32.dll", "hwnd", "CreateMutexW", "ptr", 0, "int", 1, "wstr", $sMutexName)
	If @error Then Return SetError(1, 0, 0)
	If Not $hMutex[0] Then Return SetError(1, 0, 0)
	Local $iLastError = DllCall("kernel32.dll", "dword", "GetLastError")
	If $iLastError[0] = 183 Then Return SetError(2, 0, $hMutex[0])
	If $iFlag = 1 Then
		If $iLastError[0] = 0 Then Return SetError(0, 0, $hMutex[0])
		Return SetError($iLastError[0], 0, 0)
	EndIf
	If $iLastError[0] = 0 Then Return SetError(0, 0, 0)
	Return SetError($iLastError[0], 0, 0)
EndFunc

Global $g_szMutexName = "Browser Cursor Lock"
Global $g_hMutex = _Singleton($g_szMutexName, 1)

If @error Then
	MsgBox(16, "Error", "Another instance is already running.")
	Exit
EndIf

Global $bShutdown = False

; ========== ========== ========== ========== ==========

Global $hGUI = 0, $hGraphic = 0
Global $iMessagePadding = 10
Global $iMessageTimer
Global $iMessageDuration = 0
Global $iMessageDebounce = 10

; ========== ========== ========== ========== ==========


Global $g_aGames = [ _
	[ _
		"Paper.io 2", _
		"Paper.io 2" _
	], [ _
		"Paper.io Online", _
		"Paper.io play online" _
	], [ _
		"Agar.io", _
		"Agar.io" _
	],	[ _
		"Snake.io", _
		"Play Snake Online | Snake.io" _
	] _
]

Global $browserNames

Global $g_hActiveGameWnd = 0
Global $g_bCursorLocked = False
Global $browser = False
Global $g_aBrowserWindow[4] = [0, 0, 0, 0]
Global $game = -1

; ========== ========== ========== ========== ==========

Global $configPath = @ScriptDir & "\browser cursor lock.ini"

Global $configHotkey = ""
Global $currentHotkey = ""
Global $bHotkeyLock = False

Global $configFontSize, $configDuration, $configFont, $configOpacity
Global $configSplashMessages, $configBrowserMessages, $configGameMessages
Global $configLockCursorFullscreen, $configLockCursorWindowed

Func _GetConfig()
	; Read cursor lock settings
	$configLockCursorFullscreen = Number(IniRead($configPath, "cursor", "lock_cursor_fullscreen", "1"))
	$configLockCursorWindowed = Number(IniRead($configPath, "cursor", "lock_cursor_windowed", "0"))

	; Read hotkey setting
	$configHotkey = IniRead($configPath, "general", "hotkey", "{NUMPADSUB}")
	If StringStripWS($configHotkey, 3) = "" Then $configHotkey = "{NUMPADSUB}"

	; If there's an existing hotkey, remove it before setting a new one
	If $currentHotkey <> "" And $currentHotkey <> $configHotkey Then
		; Unset the old hotkey
		HotKeySet($currentHotkey)

		; Attempt to set new hotkey
		Local $result = HotKeySet($configHotkey, "ToggleCursorLock")
		If $result = 0 Then
			MsgBox(16, "HotKey Error", "Configured hotkey '" & $configHotkey & "' could not be set.")
			Return
		Else
			$currentHotkey = $configHotkey
		EndIf
	EndIf

	; Read message display settings
	$configSplashMessages = Number(IniRead($configPath, "notifications", "splash_messages", "1"))
	$configBrowserMessages = Number(IniRead($configPath, "notifications", "browser_messages", "1"))
	$configGameMessages = Number(IniRead($configPath, "notifications", "game_messages", "1"))

	; Read and validate font size (default 24)
	$configFontSize = Number(IniRead($configPath, "message", "fontsize", "24"))
	If $configFontSize <= 0 Then $configFontSize = 24

	; Read and validate message duration (default 2000 ms)
	$configDuration = Number(IniRead($configPath, "message", "duration", "2000"))
	If $configDuration <= 0 Then $configDuration = 2000

	; Read and validate font family (default "Arial")
	$configFont = IniRead($configPath, "message", "fontfamily", "Arial")
	If StringStripWS($configFont, 3) = "" Then $configFont = "Arial"

	; Test if the font exists by attempting to create a FontFamily object.
	Local $hTestFamily = _GDIPlus_FontFamilyCreate($configFont)
	If @error Then
		MsgBox(16, "Font Error", "Configured font '" & $configFont & "' does not exist. Reverting to default 'Arial'.")
		$configFont = "Arial"
	Else
		_GDIPlus_FontFamilyDispose($hTestFamily)
	EndIf

	; Read and validate the message opacity (default 150)
	$configOpacity = Number(IniRead($configPath, "message", "opacity", "150"))
	If $configOpacity <= 0 Then $configOpacity = 150
	If $configOpacity >= 256 Then $configOpacity = 255

	; Read browser names from the INI file and split into an array
	Local $browserList = IniRead($configPath, "browsers", "names", "Brave,Google Chrome,Mozilla Firefox")
	If StringStripWS($browserList, 3) = "" Then $browserList = "Brave,Google Chrome,Mozilla Firefox"

	; Convert the comma-separated string into an array
	$browserNames = StringSplit($browserList, ",", 2)
EndFunc

; ========== ========== ========== ========== ==========

Opt("TrayMenuMode", 3)
TraySetToolTip("Browser Cursor Lock")
Global $trayMenuAbout = TrayCreateItem("About")
TrayCreateItem("")
Global $trayMenuExit = TrayCreateItem("Exit")
TraySetState($TRAY_ICONSTATE_SHOW)

; ========== ========== ========== ========== ==========

OnAutoItExitRegister("Unload")

Func _Main()
	_GDIPlus_Startup()

	_GetConfig()

	If $configSplashMessages Then
		DisplayMessage("Browser Cursor Lock")
	EndIf

	;Local $newText = ""

	While $bShutdown = False
		ProcessWindow()

		; ========== ========== ==========

		If $hGUI <> 0 Then
			Local $elapsed = TimerDiff($iMessageTimer)

			If $elapsed >= $iMessageDuration Then
				ClearMessage()
			EndIf
		EndIf

		; ========== ========== ==========

		; Check tray
		Local $nTrayMsg = TrayGetMsg()
		Switch $nTrayMsg
			Case $trayMenuAbout
				ShowAboutWindow()
			Case $trayMenuExit
				ExitScript()
			EndSwitch

		; ========== ========== ==========

		Sleep(25)

	WEnd
EndFunc

Func Unload()
	$bShutdown = True
EndFunc

Func ExitScript()
	$bShutdown = True
	_GDIPlus_Shutdown()

	If $g_hMutex Then
		DllCall("kernel32.dll", "bool", "ReleaseMutex", "hwnd", $g_hMutex)
		DllCall("kernel32.dll", "bool", "CloseHandle", "hwnd", $g_hMutex) ; Free the mutex handle
		$g_hMutex = 0
	EndIf

	Exit
EndFunc

; ========== ========== ========== ========== ==========

Func WindowPosition($hWnd)
	; Get window position
	Local $aWinPos = WinGetPos($hWnd)
	If @error Then Return SetError(1, 0, 0)
	If Not IsArray($aWinPos) Or UBound($aWinPos) < 4 Then Return SetError(2, 0, 0)

	; Default values
	Local $iMonitorX = 0, $iMonitorY = 0, $iMonitorWidth = @DesktopWidth, $iMonitorHeight = @DesktopHeight

	; Default to a missing window
	Local $iWindowX = $aWinPos[0], $iWindowY = $aWinPos[1], $iWindowWidth = $aWinPos[2], $iWindowHeight = $aWinPos[3]
	Local $iBorderTop = 0, $iBorderRight = 0, $iBorderBottom = 0, $iBorderLeft = 0
	Local $bWindowFullscreen = False

	; Use GetWindowMonitorCoverage to find the most covered monitor
	Local $aMonitorInfo = GetWindowMonitorCoverage($hWnd)
	If @error = 0 And IsArray($aMonitorInfo) Then
		$iMonitorX = $aMonitorInfo[0]
		$iMonitorY = $aMonitorInfo[1]
		$iMonitorWidth = $aMonitorInfo[2]
		$iMonitorHeight = $aMonitorInfo[3]
		$iBorderLeft = $aMonitorInfo[10]
		$iBorderTop = $aMonitorInfo[11]
		$iBorderRight = $aMonitorInfo[12]
		$iBorderBottom = $aMonitorInfo[13]
	EndIf

	; Determine if the window is fullscreen
	If $iWindowX = $iMonitorX And $iWindowY = $iMonitorY And _
	$iWindowWidth = $iMonitorWidth And $iWindowHeight = $iMonitorHeight And _
	$iBorderTop = 0 And $iBorderRight = 0 And $iBorderBottom = 0 And $iBorderLeft = 0 Then
		$bWindowFullscreen = True
	EndIf

	; Return structured data
	Local $aMonitor[4] = [$iMonitorX, $iMonitorY, $iMonitorWidth, $iMonitorHeight]
	Local $aWindow[4] = [$iWindowX, $iWindowY, $iWindowWidth, $iWindowHeight]
	Local $aBorders[4] = [$iBorderTop, $iBorderRight, $iBorderBottom, $iBorderLeft]
	Local $aFlags = $bWindowFullscreen

	Local $aReturn[4] = [$aMonitor, $aWindow, $aBorders, $aFlags]

	Return $aReturn
EndFunc

Func GetWindowMonitorCoverage($hWnd)
	; Get window position
	Local $aWinPos = WinGetPos($hWnd)
	If @error Or Not IsArray($aWinPos) Or UBound($aWinPos) < 4 Then Return SetError(1, 0, 0)

	Local $iWinX = $aWinPos[0], $iWinY = $aWinPos[1]
	Local $iWinWidth = $aWinPos[2], $iWinHeight = $aWinPos[3]
	Local $iWinArea = $iWinWidth * $iWinHeight

	; Get client rectangle size
	Local $tClientRect = _WinAPI_GetClientRect($hWnd)
	Local $iClientWidth = DllStructGetData($tClientRect, 3)
	Local $iClientHeight = DllStructGetData($tClientRect, 4)

	; Create a struct to hold the converted client position
	Local $tPoint = DllStructCreate("int X; int Y")
	DllStructSetData($tPoint, "X", 0)
	DllStructSetData($tPoint, "Y", 0)

	; Convert client (0,0) to absolute screen coordinates
	_WinAPI_ClientToScreen($hWnd, DllStructGetPtr($tPoint))

	Local $iClientLeft = DllStructGetData($tPoint, "X")
	Local $iClientTop = DllStructGetData($tPoint, "Y")

	; Calculate borders
	Local $iBorderLeft = $iClientLeft - $iWinX
	Local $iBorderTop = $iClientTop - $iWinY
	Local $iBorderRight = ($iWinWidth - $iBorderLeft - $iClientWidth)
	Local $iBorderBottom = ($iWinHeight - $iBorderTop - $iClientHeight)

	; Retrieve all monitors
	Local $aMonitors = _WinAPI_EnumDisplayMonitors()
	If Not IsArray($aMonitors) Then Return SetError(2, 0, 0)

	Local $bestMonitor = -1, $maxCoverage = 0, $bestMonitorArea = 0
	Local $monitorData[14] ; Stores [X, Y, Width, Height, Coverage %, Monitor Index, Window X, Window Y, Window Width, Window Height, Border Top, Border Right, Border Bottom, Border, Left]

	For $i = 1 To $aMonitors[0][0]
		Local $hMonitor = $aMonitors[$i][0]
		Local $aMonitorInfo = _WinAPI_GetMonitorInfo($hMonitor)
		If @error Or Not IsArray($aMonitorInfo) Then ContinueLoop

		Local $iMonLeft = DllStructGetData($aMonitorInfo[0], "Left")
		Local $iMonTop = DllStructGetData($aMonitorInfo[0], "Top")
		Local $iMonRight = DllStructGetData($aMonitorInfo[0], "Right")
		Local $iMonBottom = DllStructGetData($aMonitorInfo[0], "Bottom")

		; Calculate intersection area
		Local $iOverlapLeft = ($iWinX > $iMonLeft) ? $iWinX : $iMonLeft
		Local $iOverlapTop = ($iWinY > $iMonTop) ? $iWinY : $iMonTop
		Local $iOverlapRight = ($iWinX + $iWinWidth < $iMonRight) ? ($iWinX + $iWinWidth) : $iMonRight
		Local $iOverlapBottom = ($iWinY + $iWinHeight < $iMonBottom) ? ($iWinY + $iWinHeight) : $iMonBottom

		Local $iOverlapWidth = $iOverlapRight - $iOverlapLeft
		Local $iOverlapHeight = $iOverlapBottom - $iOverlapTop

		If $iOverlapWidth > 0 And $iOverlapHeight > 0 Then
			Local $iOverlapArea = $iOverlapWidth * $iOverlapHeight
			Local $iCoverage = ($iOverlapArea / $iWinArea) * 100

			; Keep track of the monitor with the most coverage
			If $iCoverage > $maxCoverage Then
				$maxCoverage = $iCoverage
				$bestMonitor = $hMonitor
				$bestMonitorArea = $iOverlapArea
				$monitorData[0] = $iMonLeft
				$monitorData[1] = $iMonTop
				$monitorData[2] = $iMonRight - $iMonLeft
				$monitorData[3] = $iMonBottom - $iMonTop
				$monitorData[4] = $iCoverage
				$monitorData[5] = $i
			EndIf
		EndIf
	Next

	$monitorData[6] = $iWinX
	$monitorData[7] = $iWinY
	$monitorData[8] = $iWinWidth
	$monitorData[9] = $iWinHeight
	$monitorData[10] = $iBorderTop
	$monitorData[11] = $iBorderRight
	$monitorData[12] = $iBorderBottom
	$monitorData[13] = $iBorderLeft

	; Return monitor data: [X, Y, Width, Height, Coverage %, Monitor Index]
	If $bestMonitor = -1 Then Return SetError(3, 0, 0)
	Return $monitorData
EndFunc

; ========== ========== ========== ========== ==========

Func DisplayMessage($sText, $iDuration = $configDuration, $sFontName = $configFont, $iFontSize = $configFontSize, $iOpacity = $configOpacity)
	$sText = StringStripWS($sText, 3)
	Local $aTextSize = MeasureStringSize($sText, $sFontName, $iFontSize)
	Local $iTextWidth = Ceiling($aTextSize[0]) + ($iMessagePadding * 2)
	Local $iTextHeight = Ceiling($aTextSize[1]) + ($iMessagePadding * 2)

	Local Const $LWA_ALPHA = 0x00000002

	; Get active window handle
	Local $hWnd = WinGetHandle("[ACTIVE]")
	If @error Then $hWnd = 0

	Local $aMonitorInfo = GetWindowMonitorCoverage($hWnd)
	If @error Then $aMonitorInfo = [0, 0, @DesktopWidth, @DesktopHeight]

	; Calculate message position centered on detected monitor
	Local $iMessageX = $aMonitorInfo[0] + (($aMonitorInfo[2] - $iTextWidth) / 2)
	Local $iMessageY = $aMonitorInfo[1] + (($aMonitorInfo[3] - $iTextHeight) / 2)

	; Create GUI
	If $hGUI = 0 Then
		$hGUI = GUICreate("Browser Cursor Lock", $iTextWidth, $iTextHeight, $iMessageX, $iMessageY, $WS_POPUP, _
						BitOR($WS_EX_TOPMOST, $WS_EX_LAYERED, $WS_EX_TOOLWINDOW, $WS_EX_NOACTIVATE))

		DllCall("user32.dll", "long", "SetWindowLong", "hwnd", $hGUI, "int", $GWL_EXSTYLE, "long", _
				BitOR($WS_EX_NOACTIVATE, $WS_EX_TOOLWINDOW, $WS_EX_TRANSPARENT, $WS_EX_LAYERED))

		; Set Opacity
		DllCall("user32.dll", "bool", "SetLayeredWindowAttributes", "hwnd", $hGUI, "dword", 0, "byte", $iOpacity, "dword", $LWA_ALPHA)

		WinSetOnTop($hGUI, "", 1)
		GUISetState(@SW_SHOWNA, $hGUI)
	Else
		; Move existing message window
		Local Const $SWP_NOZORDER = 0x0004
		DllCall("user32.dll", "bool", "SetWindowPos", "hwnd", $hGUI, "hwnd", 0, "int", $iMessageX, "int", $iMessageY, _
				"int", $iTextWidth, "int", $iTextHeight, "uint", $SWP_NOZORDER)

		; Set Opacity
		DllCall("user32.dll", "bool", "SetLayeredWindowAttributes", "hwnd", $hGUI, "dword", 0, "byte", $iOpacity, "dword", $LWA_ALPHA)

		; Clear the existing drawing
		_GDIPlus_GraphicsClear($hGraphic)
		_GDIPlus_GraphicsDispose($hGraphic)
		
		_WinAPI_RedrawWindow($hGUI, 0, 0, BitOR($RDW_INVALIDATE, $RDW_UPDATENOW))
	EndIf

	$hGraphic = _GDIPlus_GraphicsCreateFromHWND($hGUI)
	Local $hBrush = _GDIPlus_BrushCreateSolid(0x7F000000)
	Local $hFormat = _GDIPlus_StringFormatCreate()
	Local $hFamily = _GDIPlus_FontFamilyCreate($sFontName)
	Local $hFont = _GDIPlus_FontCreate($hFamily, $iFontSize, 0)

	Local $tLayout = _GDIPlus_RectFCreate($iMessagePadding, $iMessagePadding, $aTextSize[0], $aTextSize[1])
	Local $hRegion = _WinAPI_CreateRoundRectRgn(0, 0, $iTextWidth, $iTextHeight, $iMessagePadding * 2, $iMessagePadding * 2)

	_WinAPI_RedrawWindow($hGUI, 0, 0, BitOR($RDW_INVALIDATE, $RDW_UPDATENOW))
	Sleep(20)

	; Draw the rounded corners
	_WinAPI_SetWindowRgn($hGUI, $hRegion)

	; Draw the updated string
	_GDIPlus_GraphicsDrawStringEx($hGraphic, $sText, $hFont, $tLayout, $hFormat, $hBrush)

	_WinAPI_RedrawWindow($hGUI, 0, 0, BitOR($RDW_INVALIDATE, $RDW_UPDATENOW))

	; Cleanup GDI+ objects
	_GDIPlus_BrushDispose($hBrush)
	_GDIPlus_StringFormatDispose($hFormat)
	_GDIPlus_FontDispose($hFont)
	_GDIPlus_FontFamilyDispose($hFamily)
	_WinAPI_DeleteObject($hRegion)

	; Restart timer
	$iMessageDuration = $iDuration
	$iMessageTimer = TimerInit()
EndFunc

Func ClearMessage()
	If $hGUI <> 0 Then
		; Clear timer
		$iMessageTimer = Null
		$iMessageDuration = 0

		GUISetState(@SW_UNLOCK, $hGUI)

		; Remove the GUI
		GUIDelete($hGUI)

		; Clean up resources
		_GDIPlus_GraphicsDispose($hGraphic)
		$hGraphic = 0

		$hGUI = 0
	EndIf
EndFunc

; ========== ========== ========== ========== ==========

Func MeasureStringSize($sString, $sFontName = $configFont, $iFontSize = $configFontSize)
	; Create a Graphics object from the desktop
	Local $hDC = _WinAPI_GetDC(0)
	Local $hGraphics = _GDIPlus_GraphicsCreateFromHDC($hDC)

	; Create a FontFamily and Font object
	$hFamily = _GDIPlus_FontFamilyCreate($sFontName)
	$hFont = _GDIPlus_FontCreate($hFamily, $iFontSize, 0)

	; Define a layout rectangle
	Local $tLayout = _GDIPlus_RectFCreate(0, 0, 1000, 1000)

	; Create a StringFormat object
	Local $hFormat = _GDIPlus_StringFormatCreate()

	; Measure the string
	Local $aResult = _GDIPlus_GraphicsMeasureString($hGraphics, $sString, $hFont, $tLayout, $hFormat)

	; Extract the bounding rectangle
	Local $tBoundingBox = $aResult[0]
	Local $fWidth = DllStructGetData($tBoundingBox, "Width")
	Local $fHeight = DllStructGetData($tBoundingBox, "Height")

	; Cleanup resources
	_GDIPlus_StringFormatDispose($hFormat)
	_GDIPlus_FontDispose($hFont)
	_GDIPlus_FontFamilyDispose($hFamily)
	_GDIPlus_GraphicsDispose($hGraphics)
	_WinAPI_ReleaseDC(0, $hDC)

	; Return width and height as an array
	Local $aSize[2]
	$aSize[0] = $fWidth
	$aSize[1] = $fHeight
	Return $aSize
EndFunc

; ========== ========== ========== ========== ==========

Func ProcessWindow()
	; Get the window title and handle for the currently active window
	Local $currentHwnd = WinGetHandle("[ACTIVE]")
	If @error Or $currentHwnd = 0 Then Return

	If $currentHwnd = $hGUI And $hGUI <> 0 Then Return

	Local $aWinPos = WinGetPos($currentHwnd)
	If @error Then Return ; Exit if we can't get window position

	Local $currentWindow = WinGetTitle($currentHwnd)
	If $currentWindow = "" Then Return

	; Try finding a hyphen as a separator
	Local $lastHyphenPos = StringInStr($currentWindow, "-", 0, -1)
	If $lastHyphenPos = 0 Then $lastHyphenPos = StringInStr($currentWindow, "–", 0, -1) ; En dash
	If $lastHyphenPos = 0 Then $lastHyphenPos = StringInStr($currentWindow, "—", 0, -1) ; Em dash

	; Extract browser name from window title
	Local $titleBeforeHyphen, $titleAfterHyphen
	If $lastHyphenPos > 0 Then
		; Extract the part after the hyphen
		$titleBeforeHyphen = StringStripWS(StringLeft($currentWindow, $lastHyphenPos - 1), 3)
		$titleAfterHyphen = StringStripWS(StringMid($currentWindow, $lastHyphenPos + 1), 3)
	Else
		; Fallback: If no hyphen, assume entire title is the browser name
		$titleBeforeHyphen = ""
		$titleAfterHyphen = $currentWindow
	EndIf

	; Check if the window belongs to a known browser
	Local $isBrowser = False
	For $i = 0 To UBound($browserNames) - 1
		If StringLower($titleAfterHyphen) = StringLower(StringStripWS($browserNames[$i], 3)) Then
			$isBrowser = True
			ExitLoop
		EndIf
	Next

	; Check if the window belongs to a known game
	Local $iGameIndex = -1
	If $isBrowser And $titleBeforeHyphen <> "" Then
		For $i = 0 To UBound($g_aGames) - 1
			If StringInStr($titleBeforeHyphen, $g_aGames[$i][1]) Then
				$iGameIndex = $i
				ExitLoop
			EndIf
		Next
	EndIf

	Local $sMessageText = ""

	; Handle browser activation state if a browser is detected
	If $isBrowser Then
		If Not $browser Then
			$browser = True
			$sMessageText = $configBrowserMessages ? "Browser activated" : ""
		EndIf

		; If a game title was detected, update $game with the game index and window handle
		If $iGameIndex <> -1 Then
			If $game < 0 Or $game <> $iGameIndex Then
				$game = $iGameIndex
				$g_hActiveGameWnd = $currentHwnd

				; If there's an existing hotkey, remove it before setting a new one
				If $currentHotkey = "" Then
					; Attempt to set new hotkey
					Local $result = HotKeySet($configHotkey, "ToggleCursorLock")
					If $result = 0 Then
						MsgBox(16, "HotKey Error", "Configured hotkey '" & $configHotkey & "' could not be set.")
					Else
						$currentHotkey = $configHotkey
					EndIf
				EndIf

				If $configGameMessages Then
					$sMessageText = "Game detected: " & $g_aGames[$iGameIndex][0]
				EndIf
			EndIf

			; Only update if switching to a new game instance (different window handle)
			If $g_hActiveGameWnd <> $currentHwnd Then
				$g_hActiveGameWnd = $currentHwnd

				If $configGameMessages Then
					If $sMessageText <> "" Then
						$sMessageText &= " & game detected: " & $g_aGames[$iGameIndex][0]
					Else
						$sMessageText = "Game detected: " & $g_aGames[$iGameIndex][0]
					EndIf
				EndIf
			Else

				; If cursor is locked, check if the window has moved or resized
				If $g_bCursorLocked Then

					; Get the latest window position
					Local $aNewWindowPos = WindowPosition($g_hActiveGameWnd)
					If Not IsArray($aNewWindowPos) Then Return

					; Ensure you compare against the correct array
					If Not IsArray($aNewWindowPos[1]) Then
						ConsoleWrite("Bad window position array." & @CRLF)
						Return
					EndIf

					Local $aWinPos = $aNewWindowPos[1]

					; Compare against stored window position
					If $aWinPos[0] <> $g_aBrowserWindow[0] Or _
					$aWinPos[1] <> $g_aBrowserWindow[1] Or _
					$aWinPos[2] <> $g_aBrowserWindow[2] Or _
					$aWinPos[3] <> $g_aBrowserWindow[3] Then
						$sMessageText = "Cursor Released"
						ResetCursorLock()
					EndIf

				EndIf
			EndIf
		Else
			If $game >= 0 Then
				$game = -1
				$g_hActiveGameWnd = 0
				If $configGameMessages Then
					$sMessageText = "Game deactivated"
				EndIf
				If $g_bCursorLocked Then
					ResetCursorLock()
					If $configGameMessages Then
						$sMessageText &= " and cursor unlocked"
					EndIf
				EndIf
			EndIf
		EndIf
	Else
		If $browser Then
			$browser = False
			$game = -1
			$g_hActiveGameWnd = 0
			If $configBrowserMessages Then
				$sMessageText = "Browser deactivated"
			EndIf
			If $g_bCursorLocked Then
				ResetCursorLock()
				If $configGameMessages Then
					$sMessageText &= " and cursor unlocked"
				EndIf
			EndIf
		EndIf
	EndIf
	
	If $sMessageText <> "" Then
		DisplayMessage($sMessageText)
	EndIf
EndFunc

; ========== ========== ========== ========== ==========

Func ToggleCursorLock()
	; Prevent multiple presses
	If $bHotkeyLock Then Return
	$bHotkeyLock = True

	If $currentHotkey <> "" Then
		; Unset the old hotkey
		HotKeySet($currentHotkey)
	EndIf

	; Ensure a valid game window is detected
	If Not $g_hActiveGameWnd Or Not WinExists($g_hActiveGameWnd) Then
		DisplayMessage("No active game window detected")
		Sleep(5)
		HotKeySet($currentHotkey, ToggleCursorLock)
		$bHotkeyLock = False
		Return
	EndIf

	; If already locked, unlock it
	If $g_bCursorLocked Then
		ResetCursorLock()
		DisplayMessage("Cursor unlocked")
		Sleep(5)
		HotKeySet($currentHotkey, ToggleCursorLock)
		$bHotkeyLock = False
		Return
	EndIf

	; Retrieve window position and monitor coverage
	Local $aWindowInfo = WindowPosition($g_hActiveGameWnd)
	If @error Or Not IsArray($aWindowInfo) Then
		DisplayMessage("Failed to detect window position")
		Sleep(5)
		HotKeySet($currentHotkey, ToggleCursorLock)
		$bHotkeyLock = False
		Return
	EndIf

	; Lock cursor to window
	$g_bCursorLocked = True

	; Adjust for borders to confine inside the client area
	Local $aBorders = $aWindowInfo[2] ; Get window borders
	Local $aPos = $aWindowInfo[1] ; Get window position
	Local $bFullscreen = $aWindowInfo[3] ; Check if fullscreen

	; Store the active window's position for tracking
	For $i = 0 To 3
		$g_aBrowserWindow[$i] = $aPos[$i]
	Next

	Local $iLeft = $aPos[0] + $aBorders[3]
	Local $iTop = $aPos[1] + $aBorders[0] + 4
	Local $iRight = $iLeft + ($aPos[2] - $aBorders[1] - $aBorders[3])
	Local $iBottom = $iTop + ($aPos[3] - $aBorders[0] - $aBorders[2]) - 4

	; Create the clipping rectangle
	Local $tRect = _WinAPI_CreateRect($iLeft, $iTop, $iRight, $iBottom)

	; Apply cursor restriction
	_WinAPI_ClipCursor($tRect)

	; Display confirmation message
	If $bFullscreen Then
		DisplayMessage("Cursor locked to fullscreen game window")
	Else
		DisplayMessage("Cursor locked to game window")
	EndIf
	Sleep(5)
	HotKeySet($currentHotkey, ToggleCursorLock)
	$bHotkeyLock = False
EndFunc

Func ResetCursorLock()
	_WinAPI_ClipCursor(0)
	$g_bCursorLocked = False
	For $i = 0 To 3
		$g_aBrowserWindow[$i] = 0
	Next
	$bHotkeyLock = False
EndFunc

; ========== ========== ========== ========== ==========

Func ShowAboutWindow()
	Local $hAboutGUI = GUICreate("About Browser Cursor Lock", 320, 180, -1, -1, $WS_CAPTION + $WS_POPUP + $WS_SYSMENU)

	; Add text content
	GUICtrlCreateLabel("Browser Cursor Lock", 20, 15, 280, 25)
	GUICtrlSetFont(-1, 12, 700)

	GUICtrlCreateLabel("Version: 0.1.0", 20, 45, 280, 20)
	GUICtrlCreateLabel("Author: Brogan Scott Houston McIntyre", 20, 65, 280, 20)
	GUICtrlCreateLabel("Date: 2025-02-18", 20, 85, 280, 20)
	GUICtrlCreateLabel("License: MIT", 20, 105, 280, 20)

	; Add close button
	Local $btnClose = GUICtrlCreateButton("Close", 120, 135, 80, 30)

	GUISetState(@SW_SHOW, $hAboutGUI)

	; Handle events
	While True
		Switch GUIGetMsg()
			Case $GUI_EVENT_CLOSE, $btnClose
				GUIDelete($hAboutGUI)
				ExitLoop
		EndSwitch
	WEnd
EndFunc

; ========== ========== ========== ========== ==========

_Main()