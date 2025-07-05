#pragma compile(Out, "Browser Cursor Lock.exe")
#pragma compile(Icon, "icon.ico")
#pragma compile(FileVersion, "1.0.0.0")
#pragma compile(ProductVersion, "1.0.0.0")
#pragma compile(ProductName, "Browser Cursor Lock")
#pragma compile(CompanyName, "Brogan Scott Houston McIntyre")
#pragma compile(InternalName, "BrowserCursorLock")
#pragma compile(FileDescription, "https://github.com/TechTank/Browser-Cursor-Lock")
#pragma compile(LegalCopyright, "©2025 Brogan.at")

#include <WinAPI.au3>
#include <WinAPIHObj.au3> ; Used by the rounded rectangle
#include <WinAPIRes.au3> ; Used to get the system fonts
#include <GUIConstantsEx.au3>
#include <GUIListBox.au3>
#include <TrayConstants.au3>
#include <WindowsConstants.au3>
#include <Array.au3>
#include <Math.au3>
#include <GDIPlus.au3>

; ========== ========== ========== ========== ==========

Global $bShutdown = False
OnAutoItExitRegister("ExitScript")

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

; ========== ========== ========== ========== ==========

Global $g_hActiveWnd = 0 ; Handle for the active browser window
Global $g_bCursorLocked = False
Global $g_aBrowserWindow[4] = [0, 0, 0, 0] ; Saved rect of the browser window during toggle

Global $browser = -1 ; Index for the currrently detected browser
Global $game = -1 ; Index for the currently detected game

Global $g_hLastHwnd = 0 ; Last detected window handle
Global $g_sLastWindowTitle = "" ; Last detected window title

; ========== ========== ========== ========== ==========

Global $configPath = @ScriptDir & "\browser cursor lock.ini"

; ========== ========== ========== ========== ==========

Opt("TrayMenuMode", 3)
TraySetToolTip("Browser Cursor Lock")

Global $trayMenuConfig = TrayCreateItem("Settings")
TrayCreateItem("")
Global $trayMenuAbout = TrayCreateItem("About")
TrayCreateItem("")
Global $trayMenuExit = TrayCreateItem("Exit")

TraySetState($TRAY_ICONSTATE_SHOW)

; ========== ========== ========== ========== ==========

Func _Main()
	$hGDIP = _GDIPlus_Startup()
	If @error Then
		MsgBox(16, "Error", "Failed to initialize GDI+.")
		Exit
	EndIf

	_GetConfig()

	If $configSplashMessages Then DisplayMessage("Browser Cursor Lock")

	While Not $bShutdown
		ProcessWindow()
		If @AutoItX64 Then
			ProcessCallbackCleanup()
		EndIf

		; ========== ========== ==========

		; Handle the About GUI, if it's open
		If $bAbout Then
			Local $aMsg = GUIGetMsg(1)
			Local $iMsgID = $aMsg[0]
			Local $hMsgSource = $aMsg[1]

			If $hMsgSource = $hAboutGUI And $hAboutGUI <> 0 Then
				Switch $iMsgID
					Case $idLinkGitHub
						LinkGithubClick()

					Case $idLinkPaypal
						LinkPaypalClick()

					Case $idLinkBrave
						LinkBraveClick()

					Case $GUI_EVENT_CLOSE, $btnAboutClose
						GUIDelete($hAboutGUI)
						$hAboutGUI = 0
						$bAbout = False
				EndSwitch
			EndIf
		EndIf

		; ========== ========== ==========

		; Check tray
		Local $nTrayMsg = TrayGetMsg()
		Switch $nTrayMsg
			Case $trayMenuConfig
				ShowConfigWindow()
			Case $trayMenuAbout
				If Not WinExists($hAboutGUI) Then
					ShowAboutWindow()
				Else
					WinSetState($hAboutGUI, "", @SW_SHOW)
				EndIf
			Case $trayMenuExit
				ExitScript()
			EndSwitch

		; ========== ========== ==========

		Sleep(25)

	WEnd
EndFunc

Func ExitScript()
	If $bShutdown = False Then
		If IsDeclared("configSplashMessages") And $configSplashMessages Then
			DisplayMessage("Closing Browser Cursor Lock")
		EndIf
		$bShutdown = True
		Sleep(1000)

		_GDIPlus_Shutdown()

		If $g_hMutex Then
			; Free the mutex handle
			If @AutoItX64 Then
				DllCall("kernel32.dll", "bool", "ReleaseMutex", "ptr", $g_hMutex)
				DllCall("kernel32.dll", "bool", "CloseHandle", "ptr", $g_hMutex)
			Else
				DllCall("kernel32.dll", "bool", "ReleaseMutex", "hwnd", $g_hMutex)
				DllCall("kernel32.dll", "bool", "CloseHandle", "hwnd", $g_hMutex)
			EndIf
			$g_hMutex = 0
		EndIf

		OnAutoItExitRegister("") ; Unregisters the exit function
		Exit
	EndIf
EndFunc

; ========== ========== ========== ========== ==========

; =====
#Region Windows

Func ProcessWindow()
	; Get the window title and handle for the currently active window
	Local $currentHwnd = WinGetHandle("[ACTIVE]")
	If @error Or $currentHwnd = 0 Then Return

	; Ignore if the GUI itself is active
	If $currentHwnd = $hGUI And $hGUI <> 0 Then Return

	Local $aWinPos = WinGetPos($currentHwnd)
	If @error Then Return ; Exit if we can't get window position

	Local $currentWindow = WinGetTitle($currentHwnd)
	If $currentWindow = "" Then Return ; Skip processing if title hasn't changed

	Local $iBrowserIndex = -1
	Local $iGameIndex = -1

	; Skip processing if both the handle and title remain the same
	If $currentHwnd <> $g_hLastHwnd Or $currentWindow <> $g_sLastWindowTitle Then
		; Update cached window values
		$g_hLastHwnd = $currentHwnd
		$g_sLastWindowTitle = $currentWindow

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

		If Not IsArray($g_aBrowsers) Then Exit

		; Check if the window belongs to a known browser
		For $i = 0 To UBound($g_aBrowsers) - 1
			Local $browserRegex = StringLower(StringStripWS($g_aBrowsers[$i][2], 3))
			; Use RegEx to match the browser title
			If StringRegExp(StringLower($titleAfterHyphen), $browserRegex) Then
				$iBrowserIndex = $i
				ExitLoop
			EndIf
		Next

		; Check if the window belongs to a known game
		If $iBrowserIndex <> -1 And $titleBeforeHyphen <> "" Then
			For $i = 0 To UBound($g_aGames) - 1
				Local $gameRegex = StringLower(StringStripWS($g_aGames[$i][2], 3))
				; Use RegEx to match the game title
				If StringRegExp(StringLower($titleBeforeHyphen), $gameRegex) Then
					$iGameIndex = $i
					ExitLoop
				EndIf
			Next
		EndIf
	Else
		If $browser == -1 Then Return
		$iBrowserIndex = $browser
		$iGameIndex = $game
	EndIf

	Local $sMessageText = ""

	; Handle browser activation state if a browser is detected
	If $iBrowserIndex <> -1 Then
		If $browser = -1 Or $browser <> $iBrowserIndex Then
			$browser = $iBrowserIndex
			$sMessageText = $configBrowserMessages ? $g_aBrowsers[$iBrowserIndex][1] & " Browser activated" : ""

			If $configLockCursorAllTitles Then
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
			EndIf
		EndIf

		; If a game title was detected, update $game with the game index and window handle
		If $iGameIndex <> -1 Then
			If $game < 0 Or $game <> $iGameIndex Then
				$game = $iGameIndex
				$g_hActiveWnd = $currentHwnd

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
					$sMessageText = "Game detected: " & $g_aGames[$iGameIndex][1]
				EndIf
			EndIf

			; Only update if switching to a new game instance (different window handle)
			If $g_hActiveWnd <> $currentHwnd Then
				$g_hActiveWnd = $currentHwnd

				If $configGameMessages Then
					If $sMessageText <> "" Then
						$sMessageText &= " & game detected: " & $g_aGames[$iGameIndex][1]
					Else
						$sMessageText = "Game detected: " & $g_aGames[$iGameIndex][1]
					EndIf
				EndIf
			Else

				; If cursor is locked, check if the window has moved or resized
				If $g_bCursorLocked Then

					; Get the latest window position
					Local $aNewWindowPos = WindowPosition($g_hActiveWnd)
					If Not IsArray($aNewWindowPos) Then Return

					; Ensure you compare against the correct array
					If Not IsArray($aNewWindowPos[1]) Then Return

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
				$g_hActiveWnd = 0
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
		If $browser <> -1 Then
			$browser = -1
			$game = -1
			$g_hActiveWnd = 0
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

	If $sMessageText <> "" Then DisplayMessage($sMessageText)
EndFunc

Func WindowPosition($hWnd)
	; Get window position
	Local $aWinPos = WinGetPos($hWnd)
	If @error Then Return SetError(1, 0, 0)
	If Not IsArray($aWinPos) Or UBound($aWinPos) < 4 Then Return SetError(2, 0, 0)

	; Set the window frame variables and calculate the area of the window
	Local $iWindowX = $aWinPos[0], $iWindowY = $aWinPos[1]
	Local $iWindowWidth = $aWinPos[2], $iWindowHeight = $aWinPos[3]
	Local $iWindowArea = $iWindowWidth * $iWindowHeight

	; Get borders from registry
	Local $aBorders = GetWindowBorders()
	If @error Then
		Local $aBorders[2] = [1, 3] ; Error case
	EndIf

	; Extract border values
	Local $iBorderTop = $aBorders[0] ; Title Bar + Padded Border
	Local $iBorderRight = $aBorders[1]
	Local $iBorderBottom = $aBorders[0]
	Local $iBorderLeft = $aBorders[1]

	; Calculate client area
	Local $iClientX = $iWindowX + $iBorderLeft
	Local $iClientY = $iWindowY + $iBorderTop
	Local $iClientWidth = $iWindowWidth - ($iBorderLeft + $iBorderRight)
	Local $iClientHeight = $iWindowHeight - ($iBorderTop + $iBorderBottom)

	; ==========

	; Get client rectangle size
	Local $tClientRect = _WinAPI_GetClientRect($hWnd)
	Local $iClientRectWidth = DllStructGetData($tClientRect, 3)
	Local $iClientRectHeight = DllStructGetData($tClientRect, 4)

	; Create a struct to hold the converted client position
	Local $tPoint = DllStructCreate("int X; int Y")
	DllStructSetData($tPoint, "X", 0)
	DllStructSetData($tPoint, "Y", 0)

	; Convert client (0,0) to absolute screen coordinates
	_WinAPI_ClientToScreen($hWnd, DllStructGetPtr($tPoint))

	Local $iClientRectX = DllStructGetData($tPoint, "X")
	Local $iClientRectY = DllStructGetData($tPoint, "Y")

	; ==========

	; Retrieve all monitors
	Local $aMonitors = _WinAPI_EnumDisplayMonitors()
	If Not IsArray($aMonitors) Then Return SetError(2, 0, 0)

	Local $bestMonitor = -1, $maxCoverage = 0
	Local $aMonitor[6] = [0, 0, 0, 0, 0, 0]

	For $i = 1 To $aMonitors[0][0]
		Local $hMonitor = $aMonitors[$i][0]
		Local $aMonitorInfo = _WinAPI_GetMonitorInfo($hMonitor)
		If @error Or Not IsArray($aMonitorInfo) Then ContinueLoop

		Local $iMonitorLeft = DllStructGetData($aMonitorInfo[0], "Left")
		Local $iMonitorTop = DllStructGetData($aMonitorInfo[0], "Top")
		Local $iMonitorRight = DllStructGetData($aMonitorInfo[0], "Right")
		Local $iMonitorBottom = DllStructGetData($aMonitorInfo[0], "Bottom")

		; Calculate intersection area
		Local $iOverlapLeft = ($iWindowX > $iMonitorLeft) ? $iWindowX : $iMonitorLeft
		Local $iOverlapTop = ($iWindowY > $iMonitorTop) ? $iWindowY : $iMonitorTop
		Local $iOverlapRight = ($iWindowX + $iWindowWidth < $iMonitorRight) ? ($iWindowX + $iWindowWidth) : $iMonitorRight
		Local $iOverlapBottom = ($iWindowY + $iWindowHeight < $iMonitorBottom) ? ($iWindowY + $iWindowHeight) : $iMonitorBottom

		Local $iOverlapWidth = $iOverlapRight - $iOverlapLeft
		Local $iOverlapHeight = $iOverlapBottom - $iOverlapTop

		If $iOverlapWidth > 0 And $iOverlapHeight > 0 Then
			Local $iOverlapArea = $iOverlapWidth * $iOverlapHeight
			Local $iCoverage = ($iOverlapArea / $iWindowArea) * 100

			; Keep track of the monitor with the most coverage
			If $iCoverage > $maxCoverage Then
				$maxCoverage = $iCoverage
				$bestMonitor = $hMonitor
				$aMonitor[0] = $iMonitorLeft
				$aMonitor[1] = $iMonitorTop
				$aMonitor[2] = $iMonitorRight - $iMonitorLeft
				$aMonitor[3] = $iMonitorBottom - $iMonitorTop
				$aMonitor[4] = $iCoverage
				$aMonitor[5] = $i
			EndIf
		EndIf
	Next

	; Determine if the window is fullscreen
	Local $bWindowFullscreen = False
	If $iWindowX = $aMonitor[0] And $iWindowY = $aMonitor[1] And _
	$iWindowWidth = $aMonitor[2] And $iWindowHeight = $aMonitor[3] And _
	$iClientRectX = $aMonitor[0] And $iClientRectY = $aMonitor[1] And _
	$iClientRectWidth = $aMonitor[2] And $iClientRectHeight = $aMonitor[3] Then
		$bWindowFullscreen = True
	EndIf

	; ==========

	Local $aWindow[4] = [$iWindowX, $iWindowY, $iWindowWidth, $iWindowHeight]
	Local $aBorder[4] = [$iBorderTop, $iBorderRight, $iBorderBottom, $iBorderLeft]
	Local $aClient[4] = [$iClientX, $iClientY, $iClientWidth, $iClientHeight]
	Local $aClientRect[4] = [$iClientRectX, $iClientRectY, $iClientRectWidth, $iClientRectHeight]
	Local $aFlags = $bWindowFullscreen

	If $bestMonitor = -1 Then Return SetError(3, 0, 0)
	Local $aReturn[6] = [$aMonitor, $aWindow, $aBorders, $aClient, $aClientRect, $aFlags]
	Return $aReturn
EndFunc

Func GetWindowBorders()
	Local $sRegKey = "HKEY_CURRENT_USER\Control Panel\Desktop\WindowMetrics"

	; Read values from registry
	Local $iBorderWidth = RegRead($sRegKey, "BorderWidth")
	Local $iPaddedBorderWidth = RegRead($sRegKey, "PaddedBorderWidth")

	If @error Then Return SetError(1, 0, 0) ; Registry keys missing

	; Convert from twips (-1 twip = 1/20th of a pixel)
	$iBorderWidth = Abs($iBorderWidth) / 20
	$iPaddedBorderWidth = Abs($iPaddedBorderWidth) / 20

	; Apply DPI scaling
	Local $iDPI = _WinAPI_GetDPI()
	$iBorderWidth = Round($iBorderWidth * ($iDPI / 96))
	$iPaddedBorderWidth = Round($iPaddedBorderWidth * ($iDPI / 96))

	Local $return[2] = [$iBorderWidth, $iPaddedBorderWidth]
	Return $return
EndFunc

Func _WinAPI_GetDPI()
	Local $hDC = _WinAPI_GetDC(0)
	If @AutoItX64 Then
		Local $iDPI = DllCall("gdi32.dll", "int", "GetDeviceCaps", "ptr", $hDC, "int", 88)
	Else
		Local $iDPI = DllCall("gdi32.dll", "int", "GetDeviceCaps", "hwnd", $hDC, "int", 88)
	EndIf
	; 88 = LOGPIXELSX
	_WinAPI_ReleaseDC(0, $hDC)
	Return $iDPI[0]
EndFunc

#EndRegion
; =====

; ========== ========== ========== ========== ==========

; =====
#Region CursorLock

Func ToggleCursorLock()
	; Prevent multiple presses
	If $bHotkeyLock Then Return
	$bHotkeyLock = True

	; Unset the old hotkey
	; If $currentHotkey <> "" Then HotKeySet($currentHotkey)

	; Ensure a valid game window is detected
	If Not $configLockCursorAllTitles Then
		If Not $g_hActiveWnd Or Not WinExists($g_hActiveWnd) Then
			DisplayMessage("No active game window detected")
			Sleep(5)
			$bHotkeyLock = False
			Return
		EndIf
	EndIf

	; If already locked, unlock it
	If $g_bCursorLocked Then
		ResetCursorLock()
		DisplayMessage("Cursor unlocked")
		Sleep(5)
		$bHotkeyLock = False
		Return
	EndIf

	; Retrieve window position and monitor coverage
	Local $hWnd = 0
	If $g_hActiveWnd <> 0 Then
		$hWnd = $g_hActiveWnd
	ElseIf $g_hLastHwnd <> 0 Then
		$hWnd = $g_hLastHwnd
	EndIf

	If Not WinExists($hWnd) Then
		DisplayMessage("Selected window not found")
		Sleep(5)
		$bHotkeyLock = False
		Return
	EndIf

	Local $aWindowPosition = WindowPosition($hWnd)
	If @error Or Not IsArray($aWindowPosition) Then
		DisplayMessage("Failed to detect window position")
		Sleep(5)
		$bHotkeyLock = False
		Return
	EndIf

	; Adjust for borders to confine inside the client area
	Local $aBorders = $aWindowPosition[2] ; Get window borders
	Local $aWindow = $aWindowPosition[1] ; Get window position
	Local $aClientRect = $aWindowPosition[4] ; Get client rect
	Local $bFullscreen = $aWindowPosition[5] ; Check if fullscreen

	Local $iTop = 0, $iRight = 0, $iBottom = 0, $iLeft = 0
	Local $iBorder = $aBorders[0] + $aBorders[1]

	; Display confirmation message and prepare the clipping dimensions
	If $bFullscreen Then
		If Not $configLockCursorFullscreen Then
			DisplayMessage("Fullscreen cursor lock is disabled")
			Sleep(5)
			$bHotkeyLock = False
			Return
		EndIf

		Local $aFullBrowserOffsets = StringSplit($g_aBrowsers[$browser][4], ",", 2)
		If UBound($aFullBrowserOffsets) <> 4 Then Local $aFullBrowserOffsets = [0, 0, 0, 0]

		Local $aFullGameOffsets

		If $game <> -1 Then
			$aFullGameOffsets = StringSplit($g_aGames[$game][4], ",", 2)
			If UBound($aFullGameOffsets) <> 4 Then Local $aFullGameOffsets = [0, 0, 0, 0]
		Else
			$aFullGameOffsets = False
		EndIf

		$iTop = $aWindow[1] + $iBorder
		$iRight = $aWindow[0] + $aWindow[2]
		$iBottom = $aWindow[1] + $aWindow[3]
		$iLeft = $aWindow[0]

		If IsArray($aFullBrowserOffsets) And UBound($aFullBrowserOffsets) = 4 Then
			$iTop += Number($aFullBrowserOffsets[0])
			$iRight -= Number($aFullBrowserOffsets[1])
			$iBottom -= Number($aFullBrowserOffsets[2])
			$iLeft += Number($aFullBrowserOffsets[3])
		EndIf

		If IsArray($aFullGameOffsets) And UBound($aFullGameOffsets) = 4 Then
			$iTop += Number($aFullGameOffsets[0])
			$iRight -= Number($aFullGameOffsets[1])
			$iBottom -= Number($aFullGameOffsets[2])
			$iLeft += Number($aFullGameOffsets[3])
		EndIf

		If $game <> -1 Then
			DisplayMessage("Cursor locked to fullscreen game window")
		Else
			DisplayMessage("Cursor locked to fullscreen browser window")
		EndIf
	Else
		If Not $configLockCursorWindowed Then
			DisplayMessage("Windowed cursor lock is disabled")
			Sleep(5)
			$bHotkeyLock = False
			Return
		EndIf

		Local $aWindowBrowserOffsets = StringSplit($g_aBrowsers[$browser][3], ",", 2)
		If UBound($aWindowBrowserOffsets) <> 4 Then Local $aWindowBrowserOffsets = [0, 0, 0, 0]

		If $game <> -1 Then
			Local $aWindowGameOffsets = StringSplit($g_aGames[$game][3], ",", 2)
			If UBound($aWindowGameOffsets) <> 4 Then Local $aWindowGameOffsets = [0, 0, 0, 0]
		Else
			$aWindowGameOffsets = False
		EndIf

		$iTop = $aClientRect[1] + $iBorder
		$iRight = $aClientRect[0] + $aClientRect[2]
		$iBottom = $aClientRect[1] + $aClientRect[3]
		$iLeft = $aClientRect[0]

		If IsArray($aWindowBrowserOffsets) And UBound($aWindowBrowserOffsets) = 4 Then
			$iTop +=Number($aWindowBrowserOffsets[0])
			$iRight -= Number($aWindowBrowserOffsets[1])
			$iBottom -= Number($aWindowBrowserOffsets[2])
			$iLeft += Number($aWindowBrowserOffsets[3])
		EndIf

		If IsArray($aWindowGameOffsets) And UBound($aWindowGameOffsets) = 4 Then
			$iTop +=Number($aWindowGameOffsets[0])
			$iRight -= Number($aWindowGameOffsets[1])
			$iBottom -= Number($aWindowGameOffsets[2])
			$iLeft += Number($aWindowGameOffsets[3])
		EndIf

		If $game <> -1 Then
			DisplayMessage("Cursor locked to game window")
		Else
			DisplayMessage("Cursor locked to browser window")
		EndIf
	EndIf

	; Lock cursor to window
	$g_bCursorLocked = True

	; Store the active window's position for tracking
	For $i = 0 To 3
		$g_aBrowserWindow[$i] = $aWindow[$i]
	Next

	; Create the clipping rectangle
	Local $tRect = _WinAPI_CreateRect($iLeft, $iTop, $iRight, $iBottom)
	If @error Then
		DisplayMessage("Failed to create rectangle structure")
	Else
		; Apply cursor restriction
		Local $aResult
		If @AutoItX64 Then
			$aResult = DllCall("user32.dll", "bool", "ClipCursor", "ptr", DllStructGetPtr($tRect))
		Else
			$aResult = DllCall("user32.dll", "bool", "ClipCursor", "hwnd", DllStructGetPtr($tRect))
		EndIf
		If @error Or Not $aResult[0] Then
			DisplayMessage("Failed to clip cursor: " & @error)
		EndIf
	EndIf

	Sleep(5)
	$bHotkeyLock = False
EndFunc

Func ResetCursorLock()
	If Not $g_bCursorLocked Then Return
	_WinAPI_ClipCursor(0)
	$g_bCursorLocked = False
	For $i = 0 To 3
		$g_aBrowserWindow[$i] = 0
	Next
	$bHotkeyLock = False
EndFunc

#EndRegion
; =====

; ========== ========== ========== ========== ==========

; =====
#Region DisplayMessage

Global Const $GDIP_TEXTRENDERINGHINT_ANTIALIASGRIDFIT = 3 ; Specifies that a character is drawn using its antialiased glyph bitmap and hinting

Global $hGDIP = 0
Global $hGUI = 0, $hGraphic = 0
Global $iMessagePadding = 10
Global $iMessageTimer
Global $iMessageDuration = 0

Global $bMessageLock = False
Global $bMessagePending = False
Global $g_aCurrentMessage

Global $hClearMessageCallback = 0
Global $bCallbackLock = False

Global $iClearMessageID = 0

Global $aCallbacksToFree[0]

Func DisplayMessage($sText, $iDuration = $configDuration, $sFontName = $configFont, $iFontSize = $configFontSize, $iOpacity = $configOpacity)
	; Update the global message parameters
	Local $aMessage[5] = [$sText, $iDuration, $sFontName, $iFontSize, $iOpacity]
	$g_aCurrentMessage = $aMessage

	; If an update is already in progress, just mark that a new update is pending
	If $bMessageLock Then
		$bMessagePending = True
		Return
	EndIf

	; Otherwise, acquire the lock
	$bMessageLock = True

	If $bCallbackLock = True Then
		Do
			Sleep(10)
		Until $bCallbackLock = False
	EndIf

	Local Const $LWA_ALPHA = 0x00000002
	Local Const $SWP_NOZORDER = 0x0004

	ClearMessageTimerStop()

	; Loop to catch any pending updates that might have come in during processing
	Do
		; Clear the pending flag
		$bMessagePending = False

		; Make a local copy of the current message data
		Local $aLocalMessage = $g_aCurrentMessage

		; Use the local copy for all further processing
		Local $sLocalText = StringStripWS($aLocalMessage[0], 3)
		Local $iLocalDuration = $aLocalMessage[1]
		Local $sLocalFont = $aLocalMessage[2]
		Local $iLocalFontSize = $aLocalMessage[3]
		Local $iLocalOpacity = $aLocalMessage[4]

		; Calculate text dimensions
		Local $aTextSize = _StringInPixelsNoGUI($sLocalText, $sLocalFont, $iLocalFontSize, 0)
		If @error Then
			; Failed to set text dimensions
			$bMessageLock = False
			Return SetError(5, 0, 0)
		EndIf

		Local $iTextWidth = Ceiling($aTextSize[0]) + 3 + ($iMessagePadding * 2)
		Local $iTextHeight = Ceiling($aTextSize[1]) + ($iMessagePadding * 2)

		; Get active window handle
		Local $hWnd = WinGetHandle("[ACTIVE]")
		If @error Then $hWnd = 0
		Local $aRect[4]
		Local $aWindowPosition = WindowPosition($hWnd)
		If @error Or Not IsArray($aWindowPosition) Or Not IsArray($aWindowPosition[1]) Then
			$aRect = [0, 0, @DesktopWidth, @DesktopHeight] ; Default values
		Else
			$aRect = $aWindowPosition[0] ; Assign the array
		EndIf

		; Calculate message position centered on detected monitor
		Local $iMessageX = $aRect[0] + (($aRect[2] - $iTextWidth) / 2)
		Local $iMessageY = $aRect[1] + (($aRect[3] - $iTextHeight) / 2)

		; Create GUI
		If $hGUI = 0 Then
			$hGUI = GUICreate("Browser Cursor Lock", $iTextWidth, $iTextHeight, $iMessageX, $iMessageY, $WS_POPUP, _
											BitOR($WS_EX_TOPMOST, $WS_EX_LAYERED, $WS_EX_TOOLWINDOW, $WS_EX_NOACTIVATE))
			If @error Then
				; Failed to create the GUI
				$bMessageLock = False
				Return SetError(6, 0, 0)
			EndIf

			If @AutoItX64 Then
				DllCall("user32.dll", "ptr", "SetWindowLongPtr", "hwnd", $hGUI, "int", $GWL_EXSTYLE, "ptr", _
					BitOR($WS_EX_NOACTIVATE, $WS_EX_TOOLWINDOW, $WS_EX_TRANSPARENT, $WS_EX_LAYERED))
			Else
				DllCall("user32.dll", "long", "SetWindowLong", "hwnd", $hGUI, "int", $GWL_EXSTYLE, "long", _
					BitOR($WS_EX_NOACTIVATE, $WS_EX_TOOLWINDOW, $WS_EX_TRANSPARENT, $WS_EX_LAYERED))
			EndIf
			If @error Then
				; Failed to set window style
				GUIDelete($hGUI)
				$hGUI = 0
				$bMessageLock = False
				Return SetError(7, 0, 0)
			EndIf

			; Set Opacity
			If @AutoItX64 Then
				DllCall("user32.dll", "bool", "SetLayeredWindowAttributes", "ptr", $hGUI, "dword", 0, "byte", $iOpacity, "dword", $LWA_ALPHA)
			Else
				DllCall("user32.dll", "bool", "SetLayeredWindowAttributes", "hwnd", $hGUI, "dword", 0, "byte", $iOpacity, "dword", $LWA_ALPHA)
			EndIf

			WinSetOnTop($hGUI, "", 1)
			GUISetState(@SW_SHOWNA, $hGUI)
		Else
			; Move existing message window
			DllCall("user32.dll", "bool", "SetWindowPos", "hwnd", $hGUI, "hwnd", 0, "int", $iMessageX, "int", $iMessageY, _
					"int", $iTextWidth + 100, "int", $iTextHeight, "uint", $SWP_NOZORDER)

			; Set Opacity
			DllCall("user32.dll", "bool", "SetLayeredWindowAttributes", "hwnd", $hGUI, "dword", 0, "byte", $iLocalOpacity, "dword", $LWA_ALPHA)

			; Clear the existing drawing
			If $hGraphic <> 0 Then
				_GDIPlus_GraphicsClear($hGraphic)
				_GDIPlus_GraphicsDispose($hGraphic)
			EndIf

			_WinAPI_RedrawWindow($hGUI, 0, 0, BitOR($RDW_INVALIDATE, $RDW_UPDATENOW))
		EndIf

		$hGraphic = _GDIPlus_GraphicsCreateFromHWND($hGUI)
		_GDIPlus_GraphicsSetTextRenderingHint($hGraphic, $GDIP_TEXTRENDERINGHINT_ANTIALIASGRIDFIT)

		Local $hBrush = _GDIPlus_BrushCreateSolid(0x7F000000)
		If @error Then Return SetError(1, 0, 0)

		Local $hFormat = _GDIPlus_StringFormatCreate()
		If @error Then
			_GDIPlus_BrushDispose($hBrush)
			Return SetError(2, 0, 0)
		EndIf

		Local $aRet = DllCall($hGDIP, "int", "GdipSetStringFormatAlign", "ptr", $hFormat, "int", 0)
		If @error Or $aRet[0] <> 0 Then
			_GDIPlus_BrushDispose($hBrush)
			_GDIPlus_StringFormatDispose($hFormat)
			Return SetError(3, 0, 0)
		EndIf

		$aRet = DllCall($hGDIP, "int", "GdipSetStringFormatFlags", "ptr", $hFormat, "int", 0)
		If @error Or $aRet[0] <> 0 Then
			_GDIPlus_BrushDispose($hBrush)
			_GDIPlus_StringFormatDispose($hFormat)
			Return SetError(4, 0, 0)
		EndIf

		Local $hFamily = _GDIPlus_FontFamilyCreate($sFontName)
		Local $hFont = _GDIPlus_FontCreate($hFamily, $iFontSize, 0)

		Local $tLayout = _GDIPlus_RectFCreate($iMessagePadding - 3, $iMessagePadding, $aTextSize[0] + 100, $aTextSize[1])
		Local $hRegion = _WinAPI_CreateRoundRectRgn(0, 0, $iTextWidth, $iTextHeight, $iMessagePadding * 2, $iMessagePadding * 2)

		_WinAPI_RedrawWindow($hGUI, 0, 0, BitOR($RDW_INVALIDATE, $RDW_UPDATENOW))

		; Draw the rounded corners
		_WinAPI_SetWindowRgn($hGUI, $hRegion)

		; Draw the updated string
		_GDIPlus_GraphicsDrawStringEx($hGraphic, $sLocalText, $hFont, $tLayout, $hFormat, $hBrush)

		_WinAPI_RedrawWindow($hGUI, 0, 0, BitOR($RDW_INVALIDATE, $RDW_UPDATENOW))

		; Cleanup GDI+ objects
		_GDIPlus_BrushDispose($hBrush)
		_GDIPlus_StringFormatDispose($hFormat)
		_GDIPlus_FontDispose($hFont)
		_GDIPlus_FontFamilyDispose($hFamily)
		_WinAPI_DeleteObject($hRegion)

		; Restart timer
		$iMessageDuration = $iLocalDuration
		$iMessageTimer = TimerInit()

		; A short sleep to allow any potential new updates to set the pending flag
		Sleep(25)
	Until Not $bMessagePending

	ClearMessageTimerStart()

	; Release the lock
	$bMessageLock = False
EndFunc

Func ClearMessageTimerStart()
	If @AutoItX64 Then
		; 64-bit: third param must be "ptr" or "uint_ptr"
		$hClearMessageCallback = DllCallbackRegister("ClearMessageTimer", "int", "hwnd;uint;ptr;dword")
		$iClearMessageID = DllCall("user32.dll", "ptr", "SetTimer", "ptr", 0, "ptr", 0, "int", 50, "ptr", DllCallbackGetPtr($hClearMessageCallback))
	Else
		; 32-bit: third param is just "uint"
		$hClearMessageCallback = DllCallbackRegister("ClearMessageTimer", "int", "hwnd;uint;uint;dword")
		$iClearMessageID = DllCall("user32.dll", "int", "SetTimer", "hwnd", 0, "int", 0, "int", 50, "ptr", DllCallbackGetPtr($hClearMessageCallback))
	EndIf

	If @error Or Not IsArray($iClearMessageID) Then
		MsgBox(16, "Timer Error", "Failed to set the ClearMessage timer.")
		$iClearMessageID = 0
		DllCallbackFree($hClearMessageCallback)
		$hClearMessageCallback = 0
	EndIf
EndFunc

Func ClearMessageTimerStop()
	; If the timer is running, kill it
	If IsArray($iClearMessageID) And $iClearMessageID[0] <> 0 Then
		Local $ret
		If @AutoItX64 Then
			; In 64-bit mode, use "ptr" for the timer ID
			$ret = DllCall("user32.dll", "ptr", "KillTimer", "ptr", 0, "ptr", $iClearMessageID[0])
		Else
			; In 32-bit mode, use "int" for the timer ID
			$ret = DllCall("user32.dll", "int", "KillTimer", "hwnd", 0, "int", $iClearMessageID[0])
		EndIf
	EndIf

	Local $maxWait = 500, $waitTime = 0
	While $bCallbackLock And $waitTime < $maxWait
		Sleep(10)
		$waitTime += 10
	WEnd

	; And free the callback
	If $hClearMessageCallback <> 0 Then
		If @AutoItX64 Then
			_ArrayAdd($aCallbacksToFree, $hClearMessageCallback)
		Else
			DllCallbackFree($hClearMessageCallback)
		EndIf
		$hClearMessageCallback = 0
	EndIf

	$iClearMessageID = 0
EndFunc

Func ProcessCallbackCleanup()
	If $bCallbackLock = True Then
		Do
			Sleep(10)
		Until $bCallbackLock = False
	EndIf
	$bCallbackLock = True
	; Go through the array and free callbacks that are safe to free
	For $i = UBound($aCallbacksToFree) - 1 To 0 Step -1
		If Not $bCallbackLock Then
			DllCallbackFree($aCallbacksToFree[$i])
			_ArrayDelete($aCallbacksToFree, $i)
		EndIf
	Next
	$bCallbackLock = False
EndFunc

Func ClearMessageTimer($hWnd, $uMsg, $idEvent, $dwTime)
	If $hGUI <> 0 And $bMessageLock = False Then
		$bCallbackLock = True
		Local $elapsed = TimerDiff($iMessageTimer)
		If $elapsed >= $iMessageDuration Then ClearMessage()
		$bCallbackLock = False
	EndIf
	Return 0
EndFunc

Func ClearMessage()
	ClearMessageTimerStop()
	If $hGUI <> 0 Then
		; Clear timer
		$iMessageTimer = Null
		$iMessageDuration = 0

		If WinExists($hGUI) Then
			GUISetState(@SW_UNLOCK, $hGUI)

			; Remove the GUI
			GUIDelete($hGUI)
		EndIf

		; Clean up resources
		If $hGraphic <> 0 Then
			_GDIPlus_GraphicsDispose($hGraphic)
			$hGraphic = 0
		EndIf

		$hGUI = 0
	EndIf
EndFunc

; ========== ========== ========== ========== ==========

Func _StringInPixelsNoGUI($sString, $sFontFamily, $fSize, $iStyle, $iColWidth = 0)
	; Get the desktop DC
	Local $hDC = _WinAPI_GetDC(0)
	; Create a graphics object from the DC
	Local $hGraphic = _GDIPlus_GraphicsCreateFromHDC($hDC)

	; Set up a measurable character range covering the entire string
	Local $aRanges[2][2] = [[1]]
	$aRanges[1][0] = 0
	$aRanges[1][1] = StringLen($sString)

	; Create a StringFormat object and set it to measure character ranges
	Local $hFormat = _GDIPlus_StringFormatCreate()
	_GDIPlus_StringFormatSetMeasurableCharacterRanges($hFormat, $aRanges)

	; Create a font and set the rendering hint
	Local $hFamily = _GDIPlus_FontFamilyCreate($sFontFamily)
	If @error Then
		; Font does not exist
		_GDIPlus_StringFormatDispose($hFormat)
		_GDIPlus_GraphicsDispose($hGraphic)
		_WinAPI_ReleaseDC(0, $hDC)
		Return SetError(1, 0, 0)
	EndIf

	Local $hFont = _GDIPlus_FontCreate($hFamily, $fSize, $iStyle)
	_GDIPlus_GraphicsSetTextRenderingHint($hGraphic, $GDIP_TEXTRENDERINGHINT_ANTIALIASGRIDFIT)

	; If no column width is provided, use a large width
	If $iColWidth = 0 Then $iColWidth = 1000
	Local $tLayout = _GDIPlus_RectFCreate(0, 0, $iColWidth, 1000)

	; Measure the character ranges
	Local $aRegions = _GDIPlus_GraphicsMeasureCharacterRanges($hGraphic, $sString, $hFont, $tLayout, $hFormat)
	If Not IsArray($aRegions) Then
		_GDIPlus_FontDispose($hFont)
		_GDIPlus_FontFamilyDispose($hFamily)
		_GDIPlus_StringFormatDispose($hFormat)
		_GDIPlus_GraphicsDispose($hGraphic)
		_WinAPI_ReleaseDC(0, $hDC)
		Return
	EndIf

	Local $aBounds = _GDIPlus_RegionGetBounds($aRegions[1], $hGraphic)

	; Get the measured width and height
	Local $aWidthHeight[2] = [$aBounds[2], $aBounds[3]]

	; Clean up
	_GDIPlus_FontDispose($hFont)
	_GDIPlus_FontFamilyDispose($hFamily)
	_GDIPlus_StringFormatDispose($hFormat)
	If IsArray($aRegions) Then
		For $i = 1 To $aRegions[0]
			_GDIPlus_RegionDispose($aRegions[$i])
		Next
	EndIf
	_GDIPlus_GraphicsDispose($hGraphic)
	_WinAPI_ReleaseDC(0, $hDC)

	Return $aWidthHeight
EndFunc

#EndRegion
; =====

; ========== ========== ========== ========== ==========

; =====
#Region About

Global $bAbout = False
Global $hAboutGUI = 0
Global $btnAboutClose = 0
Global $idLinkGitHub = 0
Global $idLinkPaypal = 0
Global $idLinkBrave = 0

Global Const $SS_NOTIFY = 0x0100
Global Const $GUI_FONTUNDERLINE = 1
Global Const $GUI_CURSOR_HAND = 0

Func ShowAboutWindow()
	If $bAbout And WinExists($hAboutGUI) Then
		WinSetState($hAboutGUI, "", @SW_SHOW)
		WinActivate($hAboutGUI)
		Return
	EndIf

	$hAboutGUI = GUICreate("About Browser Cursor Lock", 400, 200, -1, -1, $WS_CAPTION + $WS_POPUP + $WS_SYSMENU)
	$bAbout = True

	; Use the .exe's internal icon
	GUICtrlCreateIcon(@ScriptFullPath, 0, 30, 10, 48, 48)

	GUICtrlCreateLabel("Browser Cursor Lock", 100, 10, 250, 25)
	GUICtrlSetFont(-1, 12, 700)
	GUICtrlCreateLabel("Version: 1.0.0.0", 100, 35, 250, 20)
	GUICtrlCreateLabel("Author: Brogan Scott Houston McIntyre", 100, 55, 300, 20)

	; GitHub link label
	$idLinkGitHub = GUICtrlCreateLabel("View on GitHub", 100, 78)
	_MakeLabelLinkStyle($idLinkGitHub)

	; Donation link label
	$idLinkPaypal = GUICtrlCreateLabel("Donate using PayPal", 100, 100)
	_MakeLabelLinkStyle($idLinkPaypal)

	; Donation link label
	$idLinkBrave = GUICtrlCreateLabel("Donate using Brave Browser Rewards", 100, 122, 200, 20)
	_MakeLabelLinkStyle($idLinkBrave)

	; A close button
	$btnAboutClose = GUICtrlCreateButton("Close", 160, 150, 80, 30)

	GUISetState(@SW_SHOW, $hAboutGUI)
EndFunc

Func LinkGitHubClick()
	DisplayMessage("Going to Github!")
	ShellExecute("https://github.com/TechTank/Browser-Cursor-Lock")
EndFunc

Func LinkPaypalClick()
	DisplayMessage("Going to Paypal!")
	ShellExecute("https://paypal.me/broganat")
EndFunc

Func LinkBraveClick()
	DisplayMessage("Going to brogan.at")
	ShellExecute("https://brogan.at/brave")
EndFunc

Func _MakeLabelLinkStyle($id)
	GUICtrlSetColor($id, 0x0000FF) ; Blue
	GUICtrlSetFont($id, Default, Default, Default, "Segoe UI") ; or any font
	GUICtrlSetCursor($id, $GUI_CURSOR_HAND) ; Hand cursor
EndFunc

#EndRegion
; =====

; ========== ========== ========== ========== ==========

; =====
#Region Configuration

Global $configHotkey = ""
Global $currentHotkey = ""
Global $bHotkeyLock = False

Global $configFontSize, $configFont, $configOpacity, $configDuration
Global $configSplashMessages, $configBrowserMessages, $configGameMessages
Global $configLockCursorFullscreen, $configLockCursorWindowed, $configLockCursorAllTitles

Global $g_sCapturedHotkey = ""
Global $bCapturing = False

; When the configuration window opens, make temporary copies
Global $tmpBrowsers
Global $tmpGames
Global $g_iSelectedBrowserIndex = -1
Global $g_iSelectedGameIndex = -1
Global $hConfigGUI = 0

;--- Configuration Window Code ---
Func ShowConfigWindow()
	ClearMessage()
	TraySetClick(0)

	$tmpBrowsers = $g_aBrowsers
	$tmpGames = $g_aGames
	$g_iSelectedBrowserIndex = -1
	$g_iSelectedGameIndex = -1

	; Temporary arrays $tmpBrowsers and $tmpGames now hold copies of the global arrays
	$hConfigGUI = GUICreate("Browser Cursor Lock - Configuration", 445, 500)
	Local Const $ES_NUMBER = 0x2000 ; Restrict input to numbers only

	; === Create Tabs ===
	Local $hTab = GUICtrlCreateTab(10, 10, 427, 445)

	; =========================
	; === General Settings Tab ===
	; =========================
	Local $hTabGeneral = GUICtrlCreateTabItem("General")
	Local $hGeneralGroup = GUICtrlCreateGroup("", 10, 40, 430, 420)

		; ---- Lock Settings ----
		Local $hLockGroup = GUICtrlCreateGroup("Lock Settings", 20, 40, 405, 90)
			Local $hLockFullscreen = GUICtrlCreateCheckbox("Lock Cursor in Fullscreen", 30, 60, 250, 20)
			Local $hLockWindowed = GUICtrlCreateCheckbox("Lock Cursor in Windowed Mode", 30, 80, 250, 20)
			Local $hLockAllTitles = GUICtrlCreateCheckbox("Lock All Browser Windows", 30, 100, 250, 20)

			GUICtrlSetState($hLockFullscreen, $configLockCursorFullscreen ? $GUI_CHECKED : $GUI_UNCHECKED)
			GUICtrlSetState($hLockWindowed, $configLockCursorWindowed ? $GUI_CHECKED : $GUI_UNCHECKED)
			GUICtrlSetState($hLockAllTitles, $configLockCursorAllTitles ? $GUI_CHECKED : $GUI_UNCHECKED)
		GUICtrlCreateGroup("", -99, -99, 1, 1) ; Close Lock Settings Group

		; ---- Hotkey Configuration ----
		Local $hHotkeyGroup = GUICtrlCreateGroup("Hotkey Settings", 20, 140, 405, 55)
			GUICtrlCreateLabel("Set Lock/Unlock Hotkey:", 40, 160, 160, 20)
			Local $hHotkeyInput = GUICtrlCreateInput($configHotkey, 170, 160, 130, 20)
			Local $hBtnStart = GUICtrlCreateButton("Start Capture", 310, 160, 100, 20)
			GUICtrlCreateGroup("", -99, -99, 1, 1) ; Close Hotkey Settings Group

			; ---- Notifications (Message Settings) ----
			Local $hMessageGroup = GUICtrlCreateGroup("Message Settings", 20, 205, 405, 90)
			Local $hSplashMessages = GUICtrlCreateCheckbox("Enable Splash Messages", 30, 225, 180, 20)
			Local $hBrowserMessages = GUICtrlCreateCheckbox("Enable Browser Detection Messages", 30, 245, 280, 20)
			Local $hGameMessages = GUICtrlCreateCheckbox("Enable Game Detection Messages", 30, 265, 280, 20)

			GUICtrlSetState($hSplashMessages, $configSplashMessages ? $GUI_CHECKED : $GUI_UNCHECKED)
			GUICtrlSetState($hBrowserMessages, $configBrowserMessages ? $GUI_CHECKED : $GUI_UNCHECKED)
			GUICtrlSetState($hGameMessages, $configGameMessages ? $GUI_CHECKED : $GUI_UNCHECKED)
		GUICtrlCreateGroup("", -99, -99, 1, 1) ; Close Message Settings Group

		; ---- Display Settings ----
		Local $hDisplayGroup = GUICtrlCreateGroup("Display Settings", 20, 300, 405, 145)
			GUICtrlCreateLabel("Message Opacity:", 40, 320, 120, 20)
			Local $hOpacitySlider = GUICtrlCreateSlider(160, 320, 180, 20)
			GUICtrlSetLimit($hOpacitySlider, 255, 1)
			GUICtrlSetData($hOpacitySlider, $configOpacity)
			Local $hOpacityLabel = GUICtrlCreateLabel(_OpacityToPercentage($configOpacity), 350, 320, 50, 20)

			GUICtrlCreateLabel("Duration (ms):", 40, 350, 120, 20)
			Local $hDuration = GUICtrlCreateInput($configDuration, 160, 350, 80, 20, $ES_NUMBER)

			GUICtrlCreateLabel("Font Size:", 40, 380, 120, 20)
			Local $hFontSize = GUICtrlCreateInput($configFontSize, 160, 380, 50, 20, $ES_NUMBER)

			GUICtrlCreateLabel("Font:", 40, 410, 120, 20)
			Local $fontList = _GetFontList()
			Local $hFontDropdown = GUICtrlCreateCombo("", 160, 410, 180, 20)
			For $i = 1 To $fontList[0]
				GUICtrlSetData($hFontDropdown, $fontList[$i])
			Next
			GUICtrlSetData($hFontDropdown, $configFont)
		GUICtrlCreateGroup("", -99, -99, 1, 1) ; End Display Group

	GUICtrlCreateGroup("", -99, -99, 1, 1) ; Close General Config Group

	; =========================
	; === Browser Configuration Tab ===
	; =========================
	Local $hTabBrowser = GUICtrlCreateTabItem("Browser Configuration")
	Local $hBrowserGroup = GUICtrlCreateGroup("", 20, 40, 450, 360)
		GUICtrlCreateLabel("Browsers:", 30, 60, 100, 20)
		Local $hBrowserList = GUICtrlCreateList("", 30, 80, 385, 120, BitOR($WS_BORDER, $WS_VSCROLL, $LBS_DISABLENOSCROLL))

		Local $sBrowserNames = "|"
		For $i = 0 To UBound($tmpBrowsers) - 1
			$sBrowserNames &= $tmpBrowsers[$i][1] & "|"
		Next
		GUICtrlSetData($hBrowserList, $sBrowserNames)

		Local $hAddBrowser = GUICtrlCreateButton("Add", 365, 45, 50, 30)
		; Editable fields for selected browser
		GUICtrlCreateLabel("ID:", 30, 220, 100, 20)
		Local $hBrowserID = GUICtrlCreateInput("", 140, 220, 200, 20)
		GUICtrlCreateLabel("Display Name:", 30, 250, 100, 20)
		Local $hBrowserDisplay = GUICtrlCreateInput("", 140, 250, 200, 20)
		GUICtrlCreateLabel("Title Regex:", 30, 280, 100, 20)
		Local $hBrowserTitle = GUICtrlCreateInput("", 140, 280, 200, 20)

		GUICtrlCreateLabel("Windowed Offsets:", 30, 310)
		GUICtrlCreateLabel("T", 180, 310, 10, 20)
		Local $hWindowOffsetT = GUICtrlCreateInput("", 195, 310, 35, 20, $ES_NUMBER)
		GUICtrlCreateLabel("R", 240, 310, 10, 20)
		Local $hWindowOffsetR = GUICtrlCreateInput("", 255, 310, 35, 20, $ES_NUMBER)
		GUICtrlCreateLabel("B", 300, 310, 10, 20)
		Local $hWindowOffsetB = GUICtrlCreateInput("", 315, 310, 35, 20, $ES_NUMBER)
		GUICtrlCreateLabel("L", 360, 310, 10, 20)
		Local $hWindowOffsetL = GUICtrlCreateInput("", 375, 310, 35, 20, $ES_NUMBER)

		GUICtrlCreateLabel("Fullscreen Offsets:", 30, 340)
		GUICtrlCreateLabel("T", 180, 340, 10, 20)
		Local $hFullscreenOffsetT = GUICtrlCreateInput("", 195, 340, 35, 20, $ES_NUMBER)
		GUICtrlCreateLabel("R", 240, 340, 10, 20)
		Local $hFullscreenOffsetR = GUICtrlCreateInput("", 255, 340, 35, 20, $ES_NUMBER)
		GUICtrlCreateLabel("B", 300, 340, 10, 20)
		Local $hFullscreenOffsetB = GUICtrlCreateInput("", 315, 340, 35, 20, $ES_NUMBER)
		GUICtrlCreateLabel("L", 360, 340, 10, 20)
		Local $hFullscreenOffsetL = GUICtrlCreateInput("", 375, 340, 35, 20, $ES_NUMBER)

		Local $hRemoveBrowser = GUICtrlCreateButton("Remove", 315, 390, 100, 30)
		GUICtrlSetState($hRemoveBrowser, $GUI_HIDE)
	GUICtrlCreateGroup("", -99, -99, 1, 1) ; End Browser Group

	Local $aBrowserControls = [$hBrowserID, $hBrowserDisplay, $hBrowserTitle, _
											 $hWindowOffsetT, $hWindowOffsetR, $hWindowOffsetB, $hWindowOffsetL, _
											 $hFullscreenOffsetT, $hFullscreenOffsetR, $hFullscreenOffsetB, $hFullscreenOffsetL]

	; =========================
	; === Game Configuration Tab ===
	; =========================
	Local $hTabGame = GUICtrlCreateTabItem("Game Configuration")
	Local $hGameGroup = GUICtrlCreateGroup("", 20, 40, 450, 360)
		GUICtrlCreateLabel("Games:", 30, 60, 100, 20)
		Local $hGameList = GUICtrlCreateList("", 30, 80, 385, 120, BitOR($WS_BORDER, $WS_VSCROLL, $LBS_DISABLENOSCROLL))
		For $i = 0 To UBound($tmpGames) - 1
			GUICtrlSetData($hGameList, $tmpGames[$i][1])
		Next
		Local $hAddGame = GUICtrlCreateButton("Add", 365, 45, 50, 30)
		; Editable fields for selected game
		GUICtrlCreateLabel("ID:", 30, 220, 100, 20)
		Local $hGameID = GUICtrlCreateInput("", 140, 220, 200, 20)
		GUICtrlCreateLabel("Display Name:", 30, 250, 100, 20)
		Local $hGameDisplay = GUICtrlCreateInput("", 140, 250, 200, 20)
		GUICtrlCreateLabel("Title Regex:", 30, 280, 100, 20)
		Local $hGameTitle = GUICtrlCreateInput("", 140, 280, 200, 20)

		GUICtrlCreateLabel("Windowed Offsets:", 30, 310)
		GUICtrlCreateLabel("T", 180, 310, 10, 20)
		Local $hGameWindowOffsetT = GUICtrlCreateInput("", 195, 310, 35, 20, $ES_NUMBER)
		GUICtrlCreateLabel("R", 240, 310, 10, 20)
		Local $hGameWindowOffsetR = GUICtrlCreateInput("", 255, 310, 35, 20, $ES_NUMBER)
		GUICtrlCreateLabel("B", 300, 310, 10, 20)
		Local $hGameWindowOffsetB = GUICtrlCreateInput("", 315, 310, 35, 20, $ES_NUMBER)
		GUICtrlCreateLabel("L", 360, 310, 10, 20)
		Local $hGameWindowOffsetL = GUICtrlCreateInput("", 375, 310, 35, 20, $ES_NUMBER)

		GUICtrlCreateLabel("Fullscreen Offsets:", 30, 340)
		GUICtrlCreateLabel("T", 180, 340, 10, 20)
		Local $hGameFullscreenOffsetT = GUICtrlCreateInput("", 195, 340, 35, 20, $ES_NUMBER)
		GUICtrlCreateLabel("R", 240, 340, 10, 20)
		Local $hGameFullscreenOffsetR = GUICtrlCreateInput("", 255, 340, 35, 20, $ES_NUMBER)
		GUICtrlCreateLabel("B", 300, 340, 10, 20)
		Local $hGameFullscreenOffsetB = GUICtrlCreateInput("", 315, 340, 35, 20, $ES_NUMBER)
		GUICtrlCreateLabel("L", 360, 340, 10, 20)
		Local $hGameFullscreenOffsetL = GUICtrlCreateInput("", 375, 340, 35, 20, $ES_NUMBER)

		Local $hRemoveGame = GUICtrlCreateButton("Remove", 315, 390, 100, 30)
		GUICtrlSetState($hRemoveGame, $GUI_HIDE)
	GUICtrlCreateGroup("", -99, -99, 1, 1) ; End Game Group

	Local $aGameControls = [$hGameID, $hGameDisplay, $hGameTitle, _
										  $hGameWindowOffsetT, $hGameWindowOffsetR, $hGameWindowOffsetB, $hGameWindowOffsetL, _
										  $hGameFullscreenOffsetT, $hGameFullscreenOffsetR, $hGameFullscreenOffsetB, $hGameFullscreenOffsetL]

	GUICtrlCreateTabItem("") ; Close Tabs

	; =========================
	; === Bottom Buttons ===
	; =========================
	Local $hSave = GUICtrlCreateButton("Save", 260, 460, 80, 30)
	Local $hCancel = GUICtrlCreateButton("Cancel", 350, 460, 80, 30)

	GUISetState(@SW_SHOW, $hConfigGUI)

	; Ensure Only the Selected Tab's Group is Visible
	Local $aGroups[3] = [$hGeneralGroup, $hBrowserGroup, $hGameGroup]
	_UpdateTabVisibility($hTab, $aGroups)

	; Initially disable all browser/game controls
	_EnableControls($aBrowserControls, False)
	_EnableControls($aGameControls, False)

	; =========================
	; === Event Loop ===
	; =========================
	While True
		Switch GUIGetMsg()
			Case $GUI_EVENT_CLOSE, $hCancel
				GUIDelete($hConfigGUI)
				TraySetClick(9)
				ExitLoop

			Case $hSave
				; Capture any changes made in browser and game list boxes
				If $g_iSelectedBrowserIndex <> -1 Then
						_CaptureBrowserFields($hBrowserList, $hBrowserID, $hBrowserDisplay, $hBrowserTitle, _
							$hWindowOffsetT, $hWindowOffsetR, $hWindowOffsetB, $hWindowOffsetL, _
							$hFullscreenOffsetT, $hFullscreenOffsetR, $hFullscreenOffsetB, $hFullscreenOffsetL)
				EndIf
				If $g_iSelectedGameIndex <> 1 Then
						_CaptureGameFields($hGameList, $hGameID, $hGameDisplay, $hGameTitle, _
							$hGameWindowOffsetT, $hGameWindowOffsetR, $hGameWindowOffsetB, $hGameWindowOffsetL, _
							$hGameFullscreenOffsetT, $hGameFullscreenOffsetR, $hGameFullscreenOffsetB, $hGameFullscreenOffsetL)
				EndIf

				; Then call SaveConfig passing all the controls
				_SaveConfig($hHotkeyInput, $hLockFullscreen, $hLockWindowed, $hLockAllTitles, _
					$hSplashMessages, $hBrowserMessages, $hGameMessages, $hFontDropdown, $hFontSize, _
					$hOpacitySlider, $hDuration)

				; Copy the temporary arrays back to globals and close the config window
				$g_aBrowsers = $tmpBrowsers
				$g_aGames = $tmpGames
				GUIDelete($hConfigGUI)
				TraySetClick(9)
				ExitLoop

			Case $hBtnStart
				$bCapturing = True
				GUICtrlSetData($hHotkeyInput, "")
				_CaptureHotkey($hHotkeyInput)

			Case $hTab
				Local $aGroups[3] = [$hGeneralGroup, $hBrowserGroup, $hGameGroup]
				_UpdateTabVisibility($hTab, $aGroups)

			Case $hOpacitySlider
				Local $newOpacity = GUICtrlRead($hOpacitySlider)
				GUICtrlSetData($hOpacityLabel, _OpacityToPercentage($newOpacity))

			Case $hBrowserList
				Local $selectedIndex = _GUICtrlListBox_GetCurSel($hBrowserList)
				If $selectedIndex <> -1 Then
					If $selectedIndex = $g_iSelectedBrowserIndex Then ContinueLoop

					; If there was a previous selection and it's different, capture its changes first
					If $g_iSelectedBrowserIndex <> -1 And $g_iSelectedBrowserIndex <> $selectedIndex Then
						_CaptureBrowserFields($hBrowserList, $hBrowserID, $hBrowserDisplay, $hBrowserTitle, _
							$hWindowOffsetT, $hWindowOffsetR, $hWindowOffsetB, $hWindowOffsetL, _
							$hFullscreenOffsetT, $hFullscreenOffsetR, $hFullscreenOffsetB, $hFullscreenOffsetL)
					EndIf

					; Update the global selected browser index
					$g_iSelectedBrowserIndex = $selectedIndex

					; Update the input fields for the new selection
					_UpdateBrowserFields($selectedIndex, $hBrowserID, $hBrowserDisplay, $hBrowserTitle, _
						$hWindowOffsetT, $hWindowOffsetR, $hWindowOffsetB, $hWindowOffsetL, _
						$hFullscreenOffsetT, $hFullscreenOffsetR, $hFullscreenOffsetB, $hFullscreenOffsetL)
					GUICtrlSetState($hRemoveBrowser, $GUI_SHOW)

					_EnableControls($aBrowserControls, True)
				Else
					_EnableControls($aBrowserControls, False)
				EndIf

			Case $hGameList
				Local $selectedIndex = _GUICtrlListBox_GetCurSel($hGameList)
				If $selectedIndex <> -1 Then
					If $g_iSelectedGameIndex = $selectedIndex Then ContinueLoop

					; If there was a previous selection and it's different, capture its changes first
					If $g_iSelectedGameIndex <> -1 And $g_iSelectedGameIndex <> $selectedIndex Then
						_CaptureGameFields($hGameList, $hGameID, $hGameDisplay, $hGameTitle, _
							$hGameWindowOffsetT, $hGameWindowOffsetR, $hGameWindowOffsetB, $hGameWindowOffsetL, _
							$hGameFullscreenOffsetT, $hGameFullscreenOffsetR, $hGameFullscreenOffsetB, $hGameFullscreenOffsetL)
					EndIf

					; Update the global selected game index
					$g_iSelectedGameIndex = $selectedIndex

					; Update the input fields for the new selection
					_UpdateGameFields($selectedIndex, $hGameID, $hGameDisplay, $hGameTitle, _
						$hGameWindowOffsetT, $hGameWindowOffsetR, $hGameWindowOffsetB, $hGameWindowOffsetL, _
						$hGameFullscreenOffsetT, $hGameFullscreenOffsetR, $hGameFullscreenOffsetB, $hGameFullscreenOffsetL)
					GUICtrlSetState($hRemoveGame, $GUI_SHOW)
					_EnableControls($aGameControls, True)
				Else
					_EnableControls($aGameControls, False)
				EndIf

			Case $hAddBrowser
				If $g_iSelectedBrowserIndex <> -1 Then
					_CaptureBrowserFields($hBrowserList, $hBrowserID, $hBrowserDisplay, $hBrowserTitle, _
						$hWindowOffsetT, $hWindowOffsetR, $hWindowOffsetB, $hWindowOffsetL, _
						$hFullscreenOffsetT, $hFullscreenOffsetR, $hFullscreenOffsetB, $hFullscreenOffsetL)
				EndIf

				; Generate a unique browser ID
				Local $sUniqueID = _GetUniqueID($tmpBrowsers, "newbrowser", 0)
				Local $defaultBrowser = [$sUniqueID, "New Browser", ".*New Browser$", "0,0,0,0", "0,0,0,0"]

				; Expand the array to have one more row
				Local $iOldRows = UBound($tmpBrowsers, 1)
				ReDim $tmpBrowsers[$iOldRows + 1][5]

				; Copy the default browser into the new row
				For $c = 0 To 4
					$tmpBrowsers[$iOldRows][$c] = $defaultBrowser[$c]
				Next

				; Append to the list
				_GUICtrlListBox_AddString($hBrowserList, $defaultBrowser[1])

				; Select the newly added browser in the list
				Local $iLastIndex = UBound($tmpBrowsers) - 1
				If $iLastIndex >= 0 Then
					_GUICtrlListBox_SetCurSel($hBrowserList, $iLastIndex)

					; Update the global selected browser index
					$g_iSelectedBrowserIndex = $iLastIndex

					; Update the input fields for the new selection
					_UpdateBrowserFields($iLastIndex, $hBrowserID, $hBrowserDisplay, $hBrowserTitle, _
						$hWindowOffsetT, $hWindowOffsetR, $hWindowOffsetB, $hWindowOffsetL, _
						$hFullscreenOffsetT, $hFullscreenOffsetR, $hFullscreenOffsetB, $hFullscreenOffsetL)
					GUICtrlSetState($hRemoveBrowser, $GUI_SHOW)
					_EnableControls($aBrowserControls, True)
				EndIf

				_WinAPI_RedrawWindow($hBrowserList, 0, 0, $RDW_INVALIDATE + $RDW_UPDATENOW)

			Case $hRemoveBrowser
				If $g_iSelectedBrowserIndex <> -1 Then
					; Remove the selected browser from the array
					_ArrayDelete($tmpBrowsers, $g_iSelectedBrowserIndex)

					; Remove from the GUI listbox
					_GUICtrlListBox_DeleteString($hBrowserList, $g_iSelectedBrowserIndex)

					; Reset global index since nothing is selected now
					$g_iSelectedBrowserIndex = -1

					; Disable and clear input fields
					_EnableControls($aBrowserControls, False)
					_ClearBrowserFields($hBrowserID, $hBrowserDisplay, $hBrowserTitle, _
						$hWindowOffsetT, $hWindowOffsetR, $hWindowOffsetB, $hWindowOffsetL, _
						$hFullscreenOffsetT, $hFullscreenOffsetR, $hFullscreenOffsetB, $hFullscreenOffsetL)

					; Hide the remove button
					GUICtrlSetState($hRemoveBrowser, $GUI_HIDE)
				EndIf

			Case $hAddGame
				; Capture the fields of the previously selected game (if any)
				If $g_iSelectedGameIndex <> -1 Then
					_CaptureGameFields($hGameList, $hGameID, $hGameDisplay, $hGameTitle, _
						$hGameWindowOffsetT, $hGameWindowOffsetR, $hGameWindowOffsetB, $hGameWindowOffsetL, _
						$hGameFullscreenOffsetT, $hGameFullscreenOffsetR, $hGameFullscreenOffsetB, $hGameFullscreenOffsetL)
				EndIf

				; Generate a unique game ID
				Local $sUniqueID = _GetUniqueID($tmpGames, "newgame", 0)
				Local $defaultGame = [$sUniqueID, "New Game", ".*New Game", "0,0,0,0", "0,0,0,0"]

				; Expand the array
				Local $iOldRows = UBound($tmpGames, 1)
				ReDim $tmpGames[$iOldRows + 1][5]

				; Copy the default game into the new row
				For $c = 0 To 4
					$tmpGames[$iOldRows][$c] = $defaultGame[$c]
				Next

				; Append to the list
				_GUICtrlListBox_AddString($hGameList, $defaultGame[1])

				; Select the newly added game in the list
				Local $iLastIndex = UBound($tmpGames) - 1
				If $iLastIndex >= 0 Then
					_GUICtrlListBox_SetCurSel($hGameList, $iLastIndex)

					; Update the global selected game index
					$g_iSelectedGameIndex = $iLastIndex

					; Update the input fields for the new selection
					_UpdateGameFields($iLastIndex, $hGameID, $hGameDisplay, $hGameTitle, _
						$hGameWindowOffsetT, $hGameWindowOffsetR, $hGameWindowOffsetB, $hGameWindowOffsetL, _
						$hGameFullscreenOffsetT, $hGameFullscreenOffsetR, $hGameFullscreenOffsetB, $hGameFullscreenOffsetL)
					GUICtrlSetState($hRemoveGame, $GUI_SHOW)
					_EnableControls($aGameControls, True)
				EndIf

				_WinAPI_RedrawWindow($hGameList, 0, 0, $RDW_INVALIDATE + $RDW_UPDATENOW)

			Case $hRemoveGame
				If $g_iSelectedGameIndex <> -1 Then
					; Remove the selected game from the array
					_ArrayDelete($tmpGames, $g_iSelectedGameIndex)

					; Remove from the GUI listbox
					_GUICtrlListBox_DeleteString($hGameList, $g_iSelectedGameIndex)

					; Reset global index since nothing is selected now
					$g_iSelectedGameIndex = -1

					; Disable and clear input fields
					_EnableControls($aGameControls, False)
					_ClearGameFields($hGameID, $hGameDisplay, $hGameTitle, _
						$hGameWindowOffsetT, $hGameWindowOffsetR, $hGameWindowOffsetB, $hGameWindowOffsetL, _
						$hGameFullscreenOffsetT, $hGameFullscreenOffsetR, $hGameFullscreenOffsetB, $hGameFullscreenOffsetL)

					; Hide the remove button
					GUICtrlSetState($hRemoveGame, $GUI_HIDE)
				EndIf
		EndSwitch
	WEnd
EndFunc

Func _EnableControls($aControls, $bEnable)
	Local $iState = $bEnable ? $GUI_ENABLE : $GUI_DISABLE
	For $i = 0 To UBound($aControls) - 1
		GUICtrlSetState($aControls[$i], $iState)
	Next
EndFunc

Func _UpdateTabVisibility($hTab, $aGroups)
	Local $iSelectedTab = GUICtrlRead($hTab) - 1
	For $i = 0 To UBound($aGroups) - 1
		GUICtrlSetState($aGroups[$i], ($i = $iSelectedTab) ? $GUI_SHOW : $GUI_HIDE)
	Next
EndFunc

Func _OpacityToPercentage($iOpacity)
	Return Round(($iOpacity / 255) * 100) & "%"
EndFunc

Func _UpdateBrowserFields($index, $hBrowserID, $hBrowserDisplay, $hBrowserTitle, _
	$hWindowOffsetT, $hWindowOffsetR, $hWindowOffsetB, $hWindowOffsetL, _
	$hFullscreenOffsetT, $hFullscreenOffsetR, $hFullscreenOffsetB, $hFullscreenOffsetL)

	If $index < 0 Or $index >= UBound($tmpBrowsers) Then Return

	GUICtrlSetData($hBrowserID, $tmpBrowsers[$index][0])
	GUICtrlSetData($hBrowserDisplay, $tmpBrowsers[$index][1])
	GUICtrlSetData($hBrowserTitle, $tmpBrowsers[$index][2])

	; Split offsets and populate individual input fields
	Local $aWindowOffsets = StringSplit($tmpBrowsers[$index][3], ",", 2)
	Local $aFullscreenOffsets = StringSplit($tmpBrowsers[$index][4], ",", 2)

	; =====

	If UBound($aWindowOffsets) >= 1 Then
		GUICtrlSetData($hWindowOffsetT, $aWindowOffsets[0])
	Else
		GUICtrlSetData($hWindowOffsetT, "0")
	EndIf

	If UBound($aWindowOffsets) >= 2 Then
		GUICtrlSetData($hWindowOffsetR, $aWindowOffsets[1])
	Else
		GUICtrlSetData($hWindowOffsetR, "0")
	EndIf

	If UBound($aWindowOffsets) >= 3 Then
		GUICtrlSetData($hWindowOffsetB, $aWindowOffsets[2])
	Else
		GUICtrlSetData($hWindowOffsetB, "0")
	EndIf

	If UBound($aWindowOffsets) >= 4 Then
		GUICtrlSetData($hWindowOffsetL, $aWindowOffsets[3])
	Else
		GUICtrlSetData($hWindowOffsetL, "0")
	EndIf

	; =====

	If UBound($aFullscreenOffsets) >= 1 Then
		GUICtrlSetData($hFullscreenOffsetT, $aFullscreenOffsets[0])
	Else
		GUICtrlSetData($hFullscreenOffsetT, "0")
	EndIf

	If UBound($aFullscreenOffsets) >= 2 Then
		GUICtrlSetData($hFullscreenOffsetR, $aFullscreenOffsets[1])
	Else
		GUICtrlSetData($hFullscreenOffsetR, "0")
	EndIf

	If UBound($aFullscreenOffsets) >= 3 Then
		GUICtrlSetData($hFullscreenOffsetB, $aFullscreenOffsets[2])
	Else
		GUICtrlSetData($hFullscreenOffsetB, "0")
	EndIf

	If UBound($aFullscreenOffsets) >= 4 Then
		GUICtrlSetData($hFullscreenOffsetL, $aFullscreenOffsets[3])
	Else
		GUICtrlSetData($hFullscreenOffsetL, "0")
	EndIf
EndFunc

Func _UpdateGameFields($index, $hGameID, $hGameDisplay, $hGameTitle, _
	$hGameWindowOffsetT, $hGameWindowOffsetR, $hGameWindowOffsetB, $hGameWindowOffsetL, _
	$hGameFullscreenOffsetT, $hGameFullscreenOffsetR, $hGameFullscreenOffsetB, $hGameFullscreenOffsetL)

	If $index < 0 Or $index >= UBound($tmpGames) Then Return

	GUICtrlSetData($hGameID, $tmpGames[$index][0])
	GUICtrlSetData($hGameDisplay, $tmpGames[$index][1])
	GUICtrlSetData($hGameTitle, $tmpGames[$index][2])

	; Split offsets and populate individual input fields
	Local $aWindowOffsets = StringSplit($tmpGames[$index][3], ",", 2)
	Local $aFullscreenOffsets = StringSplit($tmpGames[$index][4], ",", 2)

	; =====

	If UBound($aWindowOffsets) >= 1 Then
		GUICtrlSetData($hGameWindowOffsetT, $aWindowOffsets[0])
	Else
		GUICtrlSetData($hGameWindowOffsetT, "0")
	EndIf

	If UBound($aWindowOffsets) >= 2 Then
		GUICtrlSetData($hGameWindowOffsetR, $aWindowOffsets[1])
	Else
		GUICtrlSetData($hGameWindowOffsetR, "0")
	EndIf

	If UBound($aWindowOffsets) >= 3 Then
		GUICtrlSetData($hGameWindowOffsetB, $aWindowOffsets[2])
	Else
		GUICtrlSetData($hGameWindowOffsetB, "0")
	EndIf

	If UBound($aWindowOffsets) >= 4 Then
		GUICtrlSetData($hGameWindowOffsetL, $aWindowOffsets[3])
	Else
		GUICtrlSetData($hGameWindowOffsetL, "0")
	EndIf

	; =====

	If UBound($aFullscreenOffsets) >= 1 Then
		GUICtrlSetData($hGameFullscreenOffsetT, $aFullscreenOffsets[0])
	Else
		GUICtrlSetData($hGameFullscreenOffsetT, "0")
	EndIf

	If UBound($aFullscreenOffsets) >= 2 Then
		GUICtrlSetData($hGameFullscreenOffsetR, $aFullscreenOffsets[1])
	Else
		GUICtrlSetData($hGameFullscreenOffsetR, "0")
	EndIf

	If UBound($aFullscreenOffsets) >= 3 Then
		GUICtrlSetData($hGameFullscreenOffsetB, $aFullscreenOffsets[2])
	Else
		GUICtrlSetData($hGameFullscreenOffsetB, "0")
	EndIf

	If UBound($aFullscreenOffsets) >= 4 Then
		GUICtrlSetData($hGameFullscreenOffsetL, $aFullscreenOffsets[3])
	Else
		GUICtrlSetData($hGameFullscreenOffsetL, "0")
	EndIf
EndFunc

Func _CaptureBrowserFields($hBrowserList, $hBrowserID, $hBrowserDisplay, $hBrowserTitle, _
	$hWindowOffsetT, $hWindowOffsetR, $hWindowOffsetB, $hWindowOffsetL, _
	$hFullscreenOffsetT, $hFullscreenOffsetR, $hFullscreenOffsetB, $hFullscreenOffsetL)

	Local $index = $g_iSelectedBrowserIndex

	; Ensure a valid index is selected
	If $index < 0 Or $index >= UBound($tmpBrowsers) Then Return

	; Retrieve field values
	Local $id = StringStripWS(GUICtrlRead($hBrowserID), 3)
	Local $display = StringStripWS(GUICtrlRead($hBrowserDisplay), 3)
	Local $title = StringStripWS(GUICtrlRead($hBrowserTitle), 3)

	; Ensure valid values before saving
	If $id = "" Or $display = "" Then	Return

	; Save values
	$tmpBrowsers[$index][0] = $id
	$tmpBrowsers[$index][1] = $display
	$tmpBrowsers[$index][2] = $title

	; Store offsets properly
	Local $winOffsets = GUICtrlRead($hWindowOffsetT) & "," & GUICtrlRead($hWindowOffsetR) & "," & _
									GUICtrlRead($hWindowOffsetB) & "," & GUICtrlRead($hWindowOffsetL)
	Local $fullOffsets = GUICtrlRead($hFullscreenOffsetT) & "," & GUICtrlRead($hFullscreenOffsetR) & "," & _
									GUICtrlRead($hFullscreenOffsetB) & "," & GUICtrlRead($hFullscreenOffsetL)

	$tmpBrowsers[$index][3] = $winOffsets
	$tmpBrowsers[$index][4] = $fullOffsets
EndFunc

Func _CaptureGameFields($hGameList, $hGameID, $hGameDisplay, $hGameTitle, _
	$hGameWindowOffsetT, $hGameWindowOffsetR, $hGameWindowOffsetB, $hGameWindowOffsetL, _
	$hGameFullscreenOffsetT, $hGameFullscreenOffsetR, $hGameFullscreenOffsetB, $hGameFullscreenOffsetL)

	Local $index = $g_iSelectedGameIndex

	; Ensure a valid index is selected
	If $index < 0 Or $index >= UBound($tmpGames) Then Return

	; Retrieve field values
	Local $id = StringStripWS(GUICtrlRead($hGameID), 3)
	Local $display = StringStripWS(GUICtrlRead($hGameDisplay), 3)
	Local $title = StringStripWS(GUICtrlRead($hGameTitle), 3)

	; Ensure valid values before saving
	If $id = "" Or $display = "" Then Return

	; Save values
	$tmpGames[$index][0] = $id
	$tmpGames[$index][1] = $display
	$tmpGames[$index][2] = $title

	; Store offsets properly
	Local $winOffsets = GUICtrlRead($hGameWindowOffsetT) & "," & GUICtrlRead($hGameWindowOffsetR) & "," & _
									GUICtrlRead($hGameWindowOffsetB) & "," & GUICtrlRead($hGameWindowOffsetL)
	Local $fullOffsets = GUICtrlRead($hGameFullscreenOffsetT) & "," & GUICtrlRead($hGameFullscreenOffsetR) & "," & _
									GUICtrlRead($hGameFullscreenOffsetB) & "," & GUICtrlRead($hGameFullscreenOffsetL)

	$tmpGames[$index][3] = $winOffsets
	$tmpGames[$index][4] = $fullOffsets
EndFunc

Func _ClearBrowserFields($hBrowserID, $hBrowserDisplay, $hBrowserTitle, _
	$hWindowOffsetT, $hWindowOffsetR, $hWindowOffsetB, $hWindowOffsetL, _
	$hFullscreenOffsetT, $hFullscreenOffsetR, $hFullscreenOffsetB, $hFullscreenOffsetL)

	GUICtrlSetData($hBrowserID, "")
	GUICtrlSetData($hBrowserDisplay, "")
	GUICtrlSetData($hBrowserTitle, "")
	GUICtrlSetData($hWindowOffsetT, "")
	GUICtrlSetData($hWindowOffsetR, "")
	GUICtrlSetData($hWindowOffsetB, "")
	GUICtrlSetData($hWindowOffsetL, "")
	GUICtrlSetData($hFullscreenOffsetT, "")
	GUICtrlSetData($hFullscreenOffsetR, "")
	GUICtrlSetData($hFullscreenOffsetB, "")
	GUICtrlSetData($hFullscreenOffsetL, "")
EndFunc

Func _ClearGameFields($hGameID, $hGameDisplay, $hGameTitle, _
	$hGameWindowOffsetT, $hGameWindowOffsetR, $hGameWindowOffsetB, $hGameWindowOffsetL, _
	$hGameFullscreenOffsetT, $hGameFullscreenOffsetR, $hGameFullscreenOffsetB, $hGameFullscreenOffsetL)

	GUICtrlSetData($hGameID, "")
	GUICtrlSetData($hGameDisplay, "")
	GUICtrlSetData($hGameTitle, "")
	GUICtrlSetData($hGameWindowOffsetT, "")
	GUICtrlSetData($hGameWindowOffsetR, "")
	GUICtrlSetData($hGameWindowOffsetB, "")
	GUICtrlSetData($hGameWindowOffsetL, "")
	GUICtrlSetData($hGameFullscreenOffsetT, "")
	GUICtrlSetData($hGameFullscreenOffsetR, "")
	GUICtrlSetData($hGameFullscreenOffsetB, "")
	GUICtrlSetData($hGameFullscreenOffsetL, "")
EndFunc

; Write the general settings and then copies the temporary arrays
Func _SaveConfig($hHotkeyInput, $hLockFullscreen, $hLockWindowed, $hLockAllTitles, _
	$hSplashMessages, $hBrowserMessages, $hGameMessages, $hFontDropdown, $hFontSize, _
	$hOpacitySlider, $hDuration)

	Local $newHotkey = GUICtrlRead($hHotkeyInput)
	Local $lockFullscreen = GUICtrlRead($hLockFullscreen) = $GUI_CHECKED ? "1" : "0"
	Local $lockWindowed = GUICtrlRead($hLockWindowed) = $GUI_CHECKED ? "1" : "0"
	Local $lockAllTitles = GUICtrlRead($hLockAllTitles) = $GUI_CHECKED ? "1" : "0"
	Local $showSplash = GUICtrlRead($hSplashMessages) = $GUI_CHECKED ? "1" : "0"
	Local $showBrowser = GUICtrlRead($hBrowserMessages) = $GUI_CHECKED ? "1" : "0"
	Local $showGame = GUICtrlRead($hGameMessages) = $GUI_CHECKED ? "1" : "0"
	Local $fontName = GUICtrlRead($hFontDropdown)
	Local $fontSize = Number(GUICtrlRead($hFontSize))
	Local $opacity = Number(GUICtrlRead($hOpacitySlider))
	Local $duration = Number(GUICtrlRead($hDuration))

	If $fontSize <= 0 Then $fontSize = 24
	If $opacity < 1 Then $opacity = 1
	If $opacity > 255 Then $opacity = 255
	If $duration <= 0 Then $duration = 2000
	If $duration > 120000 Then $duration = 120000

	; Write general settings to the INI file
	IniWrite($configPath, "general", "hotkey", $newHotkey)
	IniWrite($configPath, "cursor", "lock_cursor_fullscreen", $lockFullscreen)
	IniWrite($configPath, "cursor", "lock_cursor_windowed", $lockWindowed)
	IniWrite($configPath, "cursor", "lock_all_titles", $lockAllTitles)
	IniWrite($configPath, "notifications", "splash_messages", $showSplash)
	IniWrite($configPath, "notifications", "browser_messages", $showBrowser)
	IniWrite($configPath, "notifications", "game_messages", $showGame)
	IniWrite($configPath, "message", "fontfamily", $fontName)
	IniWrite($configPath, "message", "fontsize", $fontSize)
	IniWrite($configPath, "message", "opacity", $opacity)
	IniWrite($configPath, "message", "duration", $duration)

	; Save browser list
	Local $sBrowserIDs = ""
	For $i = 0 To UBound($g_aBrowsers) - 1
		If StringStripWS($g_aBrowsers[$i][0], 3) <> "" Then
			$sBrowserIDs &= $g_aBrowsers[$i][0] & ","
		EndIf
	Next
	$sBrowserIDs = StringTrimRight($sBrowserIDs, 1) ; Remove trailing comma
	IniWrite($configPath, "browsers", "ids", $sBrowserIDs)

	For $i = 0 To UBound($g_aBrowsers) - 1
		If StringStripWS($g_aBrowsers[$i][0], 3) <> "" Then
			IniWrite($configPath, $g_aBrowsers[$i][0] & "_browser", "name", $g_aBrowsers[$i][1])
			IniWrite($configPath, $g_aBrowsers[$i][0] & "_browser", "title", $g_aBrowsers[$i][2])
			IniWrite($configPath, $g_aBrowsers[$i][0] & "_browser", "windowed_offsets", $g_aBrowsers[$i][3])
			IniWrite($configPath, $g_aBrowsers[$i][0] & "_browser", "fullscreen_offsets", $g_aBrowsers[$i][4])
		EndIf
	Next

	; Save game list
	Local $sGameIDs = ""
	For $i = 0 To UBound($g_aGames) - 1
		If StringStripWS($g_aGames[$i][0], 3) <> "" Then
			$sGameIDs &= $g_aGames[$i][0] & ","
		EndIf
	Next
	$sGameIDs = StringTrimRight($sGameIDs, 1) ; Remove trailing comma
	IniWrite($configPath, "games", "ids", $sGameIDs)

	For $i = 0 To UBound($g_aGames) - 1
		If StringStripWS($g_aGames[$i][0], 3) <> "" Then
			IniWrite($configPath, $g_aGames[$i][0] & "_game", "name", $g_aGames[$i][1])
			IniWrite($configPath, $g_aGames[$i][0] & "_game", "title", $g_aGames[$i][2])
			IniWrite($configPath, $g_aGames[$i][0] & "_game", "windowed_offsets", $g_aGames[$i][3])
			IniWrite($configPath, $g_aGames[$i][0] & "_game", "fullscreen_offsets", $g_aGames[$i][4])
		EndIf
	Next

	; Update the global configuration variables
	$configHotkey = $newHotkey
	$configLockCursorFullscreen = Number($lockFullscreen)
	$configLockCursorWindowed = Number($lockWindowed)
	$configLockCursorAllTitles = Number($lockAllTitles)
	$configSplashMessages = Number($showSplash)
	$configBrowserMessages = Number($showBrowser)
	$configGameMessages = Number($showGame)
	$configFont = $fontName
	$configFontSize = $fontSize
	$configOpacity = $opacity
	$configDuration = $duration

	; Reset the hotkey if it changed
	If $currentHotkey <> "" And $currentHotkey <> $configHotkey Then
		HotKeySet($currentHotkey)
		Local $result = HotKeySet($configHotkey, "ToggleCursorLock")
		If $result = 0 Then
			MsgBox(16, "HotKey Error", "New hotkey '" & $configHotkey & "' could not be set.")
			; Revert to old hotkey
			HotKeySet($currentHotkey, "ToggleCursorLock")
			$configHotkey = $currentHotkey
		Else
			$currentHotkey = $configHotkey
		EndIf
	EndIf

	MsgBox(64, "Settings Saved", "Configuration has been updated.")
EndFunc

Func _GetUniqueID(ByRef $a2D, $sBase, $iCol = 0)
	Local $sCandidate = $sBase
	Local $iCounter = 1

	; Keep appending numbers until we find an ID that isn't taken
	While _IDExists($a2D, $sCandidate, $iCol)
		$sCandidate = $sBase & $iCounter
		$iCounter += 1
	WEnd

	Return $sCandidate
EndFunc

Func _IDExists(ByRef $a2D, $sID, $iCol = 0)
	For $r = 0 To UBound($a2D, 1) - 1
		; Compare case-insensitively
		If StringLower($a2D[$r][$iCol]) = StringLower($sID) Then
			Return True
		EndIf
	Next
	Return False
EndFunc

; Get a list of system fonts
Func _GetFontList()
	Local $aData = _WinAPI_EnumFontFamilies(0, '', 0, BitOR($DEVICE_FONTTYPE, $TRUETYPE_FONTTYPE), '@*', 1) ; $ANSI_CHARSET = 0
	If @error Then
		Local $aFonts[3] = ["Arial", "Times New Roman", "Courier New"]
		Return $aFonts
	Else
		Local $iRows = UBound($aData)
		Local $aResult[$iRows]
		For $i = 0 To $iRows - 1
			$aResult[$i] = $aData[$i][0] ; assuming the first column holds the font names
		Next

		_ArraySort($aResult)
		Return $aResult
	EndIf
EndFunc

; ========== ========== ========== ========== ==========

Func _GetConfig()
	; Read hotkey setting
	$configHotkey = IniRead($configPath, "general", "hotkey", "{NUMPADSUB}")
	If StringStripWS($configHotkey, 3) = "" Then $configHotkey = "{NUMPADSUB}"

	; Read cursor lock settings
	$configLockCursorFullscreen = Number(IniRead($configPath, "cursor", "lock_cursor_fullscreen", "1"))
	$configLockCursorWindowed = Number(IniRead($configPath, "cursor", "lock_cursor_windowed", "1"))
	$configLockCursorAllTitles = Number(IniRead($configPath, "cursor", "lock_all_titles", "1"))

	; Read message display settings
	$configSplashMessages = Number(IniRead($configPath, "notifications", "splash_messages", "1"))
	$configBrowserMessages = Number(IniRead($configPath, "notifications", "browser_messages", "1"))
	$configGameMessages = Number(IniRead($configPath, "notifications", "game_messages", "1"))

	; If there's an existing hotkey, remove it before setting a new one
	If $currentHotkey <> "" And $currentHotkey <> $configHotkey Then
		; Unset the old hotkey
		HotKeySet($currentHotkey)

		; Attempt to set new hotkey
		Local $result = HotKeySet($configHotkey, "ToggleCursorLock")
		If $result = 0 Then
			MsgBox(16, "HotKey Error", "Configured hotkey '" & $configHotkey & "' could not be set.")
			$result = HotKeySet($currentHotkey, "ToggleCursorLock")
			$configHotkey = $currentHotkey
		Else
			$currentHotkey = $configHotkey
		EndIf
	EndIf

	; Read and validate font size (default 24)
	$configFontSize = Number(IniRead($configPath, "message", "fontsize", "24"))
	If $configFontSize <= 0 Then $configFontSize = 24

	; Read and validate message duration (default 2000 ms)
	$configDuration = Number(IniRead($configPath, "message", "duration", "2000"))
	If $configDuration <= 0 Then $configDuration = 2000

	; Read and validate font family (default "Arial")
	$configFont = IniRead($configPath, "message", "fontfamily", "Arial")
	If StringStripWS($configFont, 3) = "" Then $configFont = "Arial"

	; Test if the font exists by attempting to create a FontFamily object
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

	; ========== ========== ==========

	; Default browser data (used if missing from INI)
	Local $defaultBrowsers = "brave,chrome,firefox,edge,opera"
	Local $defaultBrowserData = _
		[ _
			["brave", "Brave", ".*Brave$", "77,0,0,0", "0,0,0,0"], _
			["chrome", "Chrome", ".*Google Chrome$", "83,0,0,0", "0,0,0,0"], _
			["firefox", "Firefox", ".*Mozilla Firefox$", "81,0,0,0", "0,0,0,0"], _
			["edge", "Edge", ".*Microsoft\s*.*Edge$", "70,0,0,0", "0,0,0,0"], _
			["opera", "Opera", ".*Opera$", "83,4,4,56", "-4,0,0,0"] _
		]

	; Read browser IDs from the INI file
	Local $sBrowsers = IniRead($configPath, "browsers", "ids", $defaultBrowsers)
	If StringStripWS($sBrowsers, 3) = "" Then $sBrowsers = $defaultBrowsers

	; Convert to an array
	Local $aBrowserIDs = StringSplit($sBrowsers, ",", 2)

	; Initialize browsers array
	Global $g_aBrowsers[UBound($aBrowserIDs)][5]

	; Loop through browser IDs and fetch data
	For $i = 0 To UBound($aBrowserIDs) - 1
		Local $browserID = StringStripWS($aBrowserIDs[$i], 3)
		If $browserID = "" Then ContinueLoop

		; Find default values (if any)
		Local $defaultDisplay = $browserID
		Local $defaultTitle = $browserID
		Local $defaultWindowOffsets = "0,0,0,0"
		Local $defaultFullOffsets = "0,0,0,0"

		For $j = 0 To UBound($defaultBrowserData) - 1
			If $defaultBrowserData[$j][0] = $browserID Then
				$defaultDisplay = $defaultBrowserData[$j][1]
				$defaultTitle = $defaultBrowserData[$j][2]
				$defaultWindowOffsets = $defaultBrowserData[$j][3]
				$defaultFullOffsets = $defaultBrowserData[$j][4]
				ExitLoop
			EndIf
		Next

		; Read display name (or set default)
		Local $browserDisplay = IniRead($configPath, $browserID & "_browser", "name", $defaultDisplay)

		; Read title regex(or set default)
		Local $browserTitle = IniRead($configPath, $browserID & "_browser", "title", $defaultTitle)

		; Read windowed offsets (or set default)
		Local $sWindowOffsets = StringStripWS(IniRead($configPath, $browserID & "_browser", "windowed_offsets", $defaultWindowOffsets), 3)
		$sWindowOffsets = StringRegExpReplace($sWindowOffsets, "[, ]+$", "")
		If $sWindowOffsets = "" Then $sWindowOffsets = $defaultWindowOffsets

		; Read fullscreen offsets (or set default)
		Local $sFullOffsets = StringStripWS(IniRead($configPath, $browserID & "_browser", "fullscreen_offsets", $defaultFullOffsets), 3)
		$sFullOffsets = StringRegExpReplace($sFullOffsets, "[, ]+$", "")
		 If $sFullOffsets = "" Then $sFullOffsets = $defaultFullOffsets

		; Store the browser
		$g_aBrowsers[$i][0] = $browserID
		$g_aBrowsers[$i][1] = $browserDisplay
		$g_aBrowsers[$i][2] = $browserTitle
		$g_aBrowsers[$i][3] = $sWindowOffsets
		$g_aBrowsers[$i][4] = $sFullOffsets
	Next

	; ========== ========== ==========

	; Default game data (used if missing from INI)
	Local $defaultGames = "agar,paper2,digdig,wormate,snake"
	Local $defaultGamesData = _
		[ _
			["agar", "Agar.io", "(?i)agar.io", "0,0,90,0", "0,0,90,0"], _
			["paper2", "Paper 2", "(?i)paper", "0,0,0,0", "0,0,0,0"], _
			["digdig", "Digdig", "(?i)digdig.io", "0,0,0,0", "0,0,0,0"], _
			["wormate", "Wormate", "(?i)wormate.io", "0,0,0,0", "0,0,0,0"], _
			["snake", "Snake", "(?i)snake.io", "0,0,0,0", "0,0,0,0"] _
		]

	; Read game IDs from the INI file
	Local $sGames = IniRead($configPath, "games", "ids", $defaultGames)
	If StringStripWS($sGames, 3) = "" Then $sGames = $defaultGames

	; Convert to an array
	Local $aGameIDs = StringSplit($sGames, ",", 2)

	; Initialize games array
	Global $g_aGames[UBound($aGameIDs)][5]

	; Loop through game IDs and fetch data
	For $i = 0 To UBound($aGameIDs) - 1
		Local $gameID = StringStripWS($aGameIDs[$i], 3)
		If $gameID = "" Then ContinueLoop

		; Find default values (if any)
		Local $defaultDisplay = $gameID
		Local $defaultTitle = $gameID
		Local $defaultWindowOffsets = "0,0,0,0"
		Local $defaultFullOffsets = "0,0,0,0"

		For $j = 0 To UBound($defaultGamesData) - 1
			If $defaultGamesData[$j][0] = $gameID Then
				$defaultDisplay = $defaultGamesData[$j][1]
				$defaultTitle = $defaultGamesData[$j][2]
				$defaultWindowOffsets = $defaultGamesData[$j][3]
				$defaultFullOffsets = $defaultGamesData[$j][4]
				ExitLoop
			EndIf
		Next

		; Read display name (or set default)
		Local $gameDisplay = IniRead($configPath, $gameID & "_game", "name", $defaultDisplay)

		; Read title regex(or set default)
		Local $gameTitle = IniRead($configPath, $gameID & "_game", "title", $defaultTitle)

		; Read windowed offsets (or set default)
		Local $sWindowOffsets = StringStripWS(IniRead($configPath, $gameID & "_game", "windowed_offsets", $defaultWindowOffsets), 3)
		$sWindowOffsets = StringRegExpReplace($sWindowOffsets, "[, ]+$", "")
		If $sWindowOffsets = "" Then $sWindowOffsets = $defaultWindowOffsets

		; Read fullscreen offsets (or set default)
		Local $sFullOffsets = StringStripWS(IniRead($configPath, $gameID & "_game", "fullscreen_offsets", $defaultFullOffsets), 3)
		$sFullOffsets = StringRegExpReplace($sFullOffsets, "[, ]+$", "")
		If $sFullOffsets = "" Then $sFullOffsets = $defaultFullOffsets

		; Store in game array
		$g_aGames[$i][0] = $gameID
		$g_aGames[$i][1] = $gameDisplay
		$g_aGames[$i][2] = $gameTitle
		$g_aGames[$i][3] = $sWindowOffsets
		$g_aGames[$i][4] = $sFullOffsets
	Next
EndFunc

#EndRegion
; =====

; ========== ========== ========== ========== ==========

; =====
#Region HotKeyCapture

Func _CaptureHotkey($hInput)
	Local $lastKeys = ""

	$g_sCapturedHotkey = ""
	GUICtrlSetBkColor($hInput, 0xFFFF00) ; Yellow glow to indicate active capture

	While $bCapturing
		Dim $pressedKeys[0] ; Initialize fresh for each loop iteration
		Dim $modifiers[0], $regularKeys[0]

		; Detect multiple key presses
		For $i = 1 To 255
			If _IsPressed(Hex($i, 2)) Then
				Local $keyName = _GetKeyName(Hex($i, 2))
				If $keyName <> "" And Not _ArrayContains($pressedKeys, $keyName) Then
					_ArrayAdd($pressedKeys, $keyName)
				EndIf
			EndIf
		Next

		; If keys are released, finalize capture
		If UBound($pressedKeys) = 0 And $lastKeys <> "" Then
			$bCapturing = False
			GUICtrlSetBkColor($hInput, _WinAPI_GetSysColor($COLOR_WINDOW)) ; Restore the original color
			GUICtrlSetData($hInput, ConvertToHotkeyString($g_sCapturedHotkey))
			Return
		EndIf

		; Sort into modifier keys and normal keys
		For $i = 0 To UBound($pressedKeys) - 1
			Switch $pressedKeys[$i]
				Case "LCTRL", "RCTRL", "CTRL"
					_ArrayAdd($modifiers, $pressedKeys[$i])
				Case "LALT", "RALT", "ALT"
					_ArrayAdd($modifiers, $pressedKeys[$i])
				Case "LSHIFT", "RSHIFT", "SHIFT"
					_ArrayAdd($modifiers, $pressedKeys[$i])
				Case "LWIN", "RWIN", "WIN"
					_ArrayAdd($modifiers, $pressedKeys[$i])
				Case Else
					_ArrayAdd($regularKeys, $pressedKeys[$i])
			EndSwitch
		Next

		_RemoveDuplicates($modifiers)
		; Filter out generic keys if a side-specific key is present
		$modifiers = _FilterModifiers($modifiers)

		; Merge ordered modifiers + normal keys
		Dim $orderedKeys[0]
		_ArrayMerge($orderedKeys, $modifiers)
		_ArrayMerge($orderedKeys, $regularKeys)

		If UBound($orderedKeys) > 0 Then
			$g_sCapturedHotkey = _StringJoin($orderedKeys, " + ")
			GUICtrlSetData($hInput, ConvertToHotkeyString($g_sCapturedHotkey))
			$lastKeys = $g_sCapturedHotkey
		EndIf

		Sleep(100)
	WEnd
EndFunc

; This function removes generic keys (e.g., "ALT") if a side-specific one exists (e.g., "LALT" or "RALT")
Func _FilterModifiers(ByRef $modifiers)
	Local $filtered[0]
	For $i = 0 To UBound($modifiers) - 1
		Local $mod = $modifiers[$i]
		Switch $mod
			Case "CTRL"
				; If either LCTRL or RCTRL is in the array, skip generic CTRL
				If _ArrayContains($modifiers, "LCTRL") Or _ArrayContains($modifiers, "RCTRL") Then ContinueLoop
			Case "ALT"
				If _ArrayContains($modifiers, "LALT") Or _ArrayContains($modifiers, "RALT") Then ContinueLoop
			Case "SHIFT"
				If _ArrayContains($modifiers, "LSHIFT") Or _ArrayContains($modifiers, "RSHIFT") Then ContinueLoop
			Case "WIN"
				If _ArrayContains($modifiers, "LWIN") Or _ArrayContains($modifiers, "RWIN") Then ContinueLoop
		EndSwitch
		_ArrayAdd($filtered, $mod)
	Next
	Return $filtered
EndFunc

Func _GetKeyName($hexKey)
	Local $keyMap = ObjCreate("Scripting.Dictionary")

	; Mouse Buttons
	;$keyMap.Add("01", "LMB")
	;$keyMap.Add("02", "RMB")
	;$keyMap.Add("04", "MMB")
	;$keyMap.Add("05", "MB4")
	;$keyMap.Add("06", "MB5")

	; Common Keys
	$keyMap.Add("03", "CANCEL")
	$keyMap.Add("08", "BACKSPACE")
	$keyMap.Add("09", "TAB")
	$keyMap.Add("0D", "ENTER")
	$keyMap.Add("10", "SHIFT")
	$keyMap.Add("11", "CTRL")
	$keyMap.Add("12", "ALT")
	$keyMap.Add("1B", "ESC")
	$keyMap.Add("20", "SPACE")
	$keyMap.Add("5B", "LWIN")
	$keyMap.Add("5C", "RWIN")

	; Additional Navigation Keys
	$keyMap.Add("21", "PGUP")
	$keyMap.Add("22", "PGDN")
	$keyMap.Add("23", "END")
	$keyMap.Add("24", "HOME")
	$keyMap.Add("25", "LEFT")
	$keyMap.Add("26", "UP")
	$keyMap.Add("27", "RIGHT")
	$keyMap.Add("28", "DOWN")
	$keyMap.Add("2D", "INSERT")
	$keyMap.Add("2E", "DELETE")

	; Additional System Keys
	$keyMap.Add("2C", "PRTSC")
	$keyMap.Add("13", "PAUSE")
	$keyMap.Add("14", "CAPSLOCK")
	$keyMap.Add("91", "SCROLLLOCK")
	$keyMap.Add("5D", "APPS")

	; Numpad Keys
	$keyMap.Add("60", "NUMPAD0")
	$keyMap.Add("61", "NUMPAD1")
	$keyMap.Add("62", "NUMPAD2")
	$keyMap.Add("63", "NUMPAD3")
	$keyMap.Add("64", "NUMPAD4")
	$keyMap.Add("65", "NUMPAD5")
	$keyMap.Add("66", "NUMPAD6")
	$keyMap.Add("67", "NUMPAD7")
	$keyMap.Add("68", "NUMPAD8")
	$keyMap.Add("69", "NUMPAD9")
	$keyMap.Add("6A", "NUMPADMULT")
	$keyMap.Add("6B", "NUMPADADD")
	$keyMap.Add("6D", "NUMPADSUB")
	$keyMap.Add("6E", "NUMPADDECIMAL")
	$keyMap.Add("6F", "NUMPADDIV")

	; OEM / Punctuation Keys
	$keyMap.Add("BA", "SEMICOLON")			; VK_OEM_1 (e.g., ;)
	$keyMap.Add("BB", "EQUALS")				; VK_OEM_PLUS (e.g., =)
	$keyMap.Add("BC", "COMMA")				; VK_OEM_COMMA (e.g., ,)
	$keyMap.Add("BD", "MINUS")					; VK_OEM_MINUS (e.g., -)
	$keyMap.Add("BE", "PERIOD")				; VK_OEM_PERIOD (e.g., .)
	$keyMap.Add("BF", "FORWARD_SLASH")	; VK_OEM_2 (e.g., /)
	$keyMap.Add("C0", "TILDE")					; VK_OEM_3 (e.g., ~ or `)
	$keyMap.Add("DB", "OPEN_BRACKET")	; VK_OEM_4 (e.g., [)
	$keyMap.Add("DC", "BACKSLASH")			; VK_OEM_5 (e.g., \)
	$keyMap.Add("DD", "CLOSE_BRACKET")	; VK_OEM_6 (e.g., ])
	$keyMap.Add("DE", "APOSTROPHE")		; VK_OEM_7 (e.g., ')
	$keyMap.Add("DF", "OEM_8")

	; Media / Special Function Keys
	;$keyMap.Add("AD", "VOLUME_MUTE")	; Volume Mute
	;$keyMap.Add("AE", "VOLUME_DOWN")	; Volume Down
	;$keyMap.Add("AF", "VOLUME_UP")		; Volume Up
	;$keyMap.Add("B0", "NEXT_TRACK")		; Next Track
	;$keyMap.Add("B1", "PREV_TRACK")		; Previous Track
	;$keyMap.Add("B2", "STOP")					; Stop
	;$keyMap.Add("B3", "PLAY_PAUSE")		; Play/Pause

	; Additional Special Keys
	;$keyMap.Add("0C", "CLEAR")					; Clear key (often on numpad)
	;$keyMap.Add("29", "SELECT")				; Select key
	;$keyMap.Add("5F", "SLEEP")					; Sleep key

	; Browser Keys
	;$keyMap.Add("A6", "BROWSER_BACK")
	;$keyMap.Add("A7", "BROWSER_FORWARD")
	;$keyMap.Add("A8", "BROWSER_REFRESH")
	;$keyMap.Add("A9", "BROWSER_STOP")
	;$keyMap.Add("AA", "BROWSER_SEARCH")
	;$keyMap.Add("AB", "BROWSER_FAVORITES")
	;$keyMap.Add("AC", "BROWSER_HOME")

	; Launch/Application Keys
	;$keyMap.Add("B4", "LAUNCH_MAIL")
	;$keyMap.Add("B5", "LAUNCH_MEDIA_SELECT")
	;$keyMap.Add("B6", "LAUNCH_APP1")		; Often used for Calculator
	;$keyMap.Add("B7", "LAUNCH_APP2")		; Additional launch key

	; Additional OEM / Special Keys
	;$keyMap.Add("E1", "OEM_AX")
	;$keyMap.Add("E2", "OEM_102")
	;$keyMap.Add("E5", "PROCESSKEY")

	; Additional Rare Keys
	;$keyMap.Add("F6", "ATTN")
	;$keyMap.Add("F7", "CRSEL")
	;$keyMap.Add("F8", "EXSEL")
	;$keyMap.Add("F9", "EREOF")
	;$keyMap.Add("FA", "PLAY")
	;$keyMap.Add("FB", "ZOOM")
	;$keyMap.Add("FC", "NONAME")
	;$keyMap.Add("FD", "PA1")
	;$keyMap.Add("FE", "OEM_CLEAR")

	; Numbers
	For $i = 0 To 9
		$keyMap.Add(Hex(48 + $i, 2), String($i))
	Next

	; Letters
	For $i = 0 To 25
		$keyMap.Add(Hex(65 + $i, 2), Chr(65 + $i))
	Next

	; Function keys
	For $i = 1 To 24
		If $i = 12 Then ContinueLoop ; Skip F12 since it's reserved by Windows
		$keyMap.Add(Hex(111 + $i, 2), "F" & $i)
	Next

	; Modifier Keys
	$keyMap.Add("A0", "LSHIFT")
	$keyMap.Add("A1", "RSHIFT")
	$keyMap.Add("A2", "LCTRL")
	$keyMap.Add("A3", "RCTRL")
	$keyMap.Add("A4", "LALT")
	$keyMap.Add("A5", "RALT")

	If $keyMap.Exists($hexKey) Then Return $keyMap.Item($hexKey)

	Return "KEY_" & $hexKey
EndFunc

Func _ArrayMerge(ByRef $array, $addArray)
	For $i = 0 To UBound($addArray) - 1
		_ArrayAdd($array, $addArray[$i])
	Next
EndFunc

Func _ArrayContains($array, $value)
	For $i = 0 To UBound($array) - 1
		If $array[$i] = $value Then Return True
	Next
	Return False
EndFunc

Func _StringJoin($array, $separator)
	Local $result = ""
	For $i = 0 To UBound($array) - 1
		$result &= $array[$i] & $separator
	Next
	Return StringTrimRight($result, StringLen($separator))
EndFunc

Func _RemoveDuplicates(ByRef $array)
	Local $tempArray[0]
	For $i = 0 To UBound($array) - 1
		If Not _ArrayContains($tempArray, $array[$i]) Then _ArrayAdd($tempArray, $array[$i])
	Next
	$array = $tempArray
EndFunc

Func _IsPressed($sHexKey, $vDLL = "user32.dll")
	If @AutoItX64 Then
		Local $aCall = DllCall($vDLL, "int", "GetAsyncKeyState", "int", "0x" & $sHexKey)
	Else
		Local $aCall = DllCall($vDLL, "short", "GetAsyncKeyState", "int", "0x" & $sHexKey)
	EndIf
	If @error Then Return SetError(@error, @extended, False)
	Return BitAND($aCall[0], 0x8000) <> 0
EndFunc

Func ConvertToHotkeyString($sCaptured)
	; Remove extra whitespace and standardize the separator
	$sCaptured = StringStripWS($sCaptured, 3)		; trim whitespace from both ends
	Local $aKeys = StringSplit($sCaptured, "+", 1)	; split on '+'
	If $aKeys[0] = 0 Then Return ""

	Local $sHotkey = ""
	Local $bBaseFound = False ; flag to track if we've added a base key

	For $i = 1 To $aKeys[0]
		Local $sKey = StringUpper(StringStripWS($aKeys[$i], 3))
		Switch $sKey
			Case "LCTRL", "RCTRL", "CTRL"
				$sHotkey &= "^"
			Case "LALT", "RALT", "ALT"
				$sHotkey &= "!"
			Case "LSHIFT", "RSHIFT", "SHIFT"
				$sHotkey &= "+"
			Case "LWIN", "RWIN", "WIN"
				$sHotkey &= "#"
			Case Else
				; Only add one non-modifier key (the "base" key)
				If Not $bBaseFound Then
					$bBaseFound = True
					; If it's a single character (letter, digit, punctuation), use it directly (lowercase preferred)
					If StringLen($sKey) = 1 Then
						$sHotkey &= StringLower($sKey)
					Else
						; For special keys (like F1, ESC, ENTER, etc.), ensure they are enclosed in braces
						If StringInStr($sKey, "{") = 0 Then
							$sHotkey &= "{" & $sKey & "}"
						Else
							$sHotkey &= $sKey
						EndIf
					EndIf
				Else
					; Ignore additional non-modifier keys
					ContinueLoop
				EndIf
		EndSwitch
	Next
	Return $sHotkey
EndFunc

#EndRegion
; =====

; ========== ========== ========== ========== ==========

_Main()