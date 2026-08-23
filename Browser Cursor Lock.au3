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
#include <WinAPIGdi.au3>
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
	Local $aMutex = DllCall("kernel32.dll", "handle", "CreateMutexW", "ptr", 0, "int", 1, "wstr", $sMutexName)
	If @error Or Not IsArray($aMutex) Or Not $aMutex[0] Then Return SetError(1, 0, 0)

	Local $hMutex = $aMutex[0]
	Local $aLastError = DllCall("kernel32.dll", "dword", "GetLastError")
	If @error Or Not IsArray($aLastError) Then
		DllCall("kernel32.dll", "bool", "CloseHandle", "handle", $hMutex)
		Return SetError(3, 0, 0)
	EndIf

	Local $iLastError = $aLastError[0]

	; ERROR_ALREADY_EXISTS means another copy owns/created the named mutex
	If $iLastError = 183 Then
		DllCall("kernel32.dll", "bool", "CloseHandle", "handle", $hMutex)
		Return SetError(2, 0, 0)
	EndIf

	If $iFlag = 1 Then
		If $iLastError = 0 Then Return SetError(0, 0, $hMutex)
		DllCall("kernel32.dll", "bool", "CloseHandle", "handle", $hMutex)
		Return SetError($iLastError, 0, 0)
	EndIf

	If $iLastError = 0 Then
		DllCall("kernel32.dll", "bool", "CloseHandle", "handle", $hMutex)
		Return SetError(0, 0, 0)
	EndIf

	DllCall("kernel32.dll", "bool", "CloseHandle", "handle", $hMutex)
	Return SetError($iLastError, 0, 0)
EndFunc

Global $g_szMutexName = "Browser Cursor Lock"
Global $g_hMutex = _Singleton($g_szMutexName, 1)
Global $g_iSingletonInitError = @error

If $g_iSingletonInitError Then
	If $g_iSingletonInitError = 2 Then
		MsgBox(16, "Error", "Another instance is already running.")
	Else
		MsgBox(16, "Error", "Browser Cursor Lock could not create its single-instance mutex (error " & $g_iSingletonInitError & ").")
	EndIf
	Exit
EndIf

; ========== ========== ========== ========== ==========

Global $g_hActiveHwnd = 0 ; Handle for the active browser window
Global $g_hLastHwnd = 0 ; Handle for the last detected window
Global $g_hCursorLockHwnd = 0 ; Handle for the clip cursor calculation

Global $g_sLastWindowTitle = "" ; Last detected window title
Global $g_bTransientWindow = False

Global $g_bCursorLocked = False
Global $g_bCursorAutoLocked = False

Global $g_bAutoLockSuppressed = False
Global $g_hAutoLockSuppressedHwnd = 0

Global $g_aBrowserRect[4] = [0, 0, 0, 0] ; Rect of the browser window during toggle
Global $g_aCursorClipRect[4] = [0, 0, 0, 0] ; Expected cursor clip [Left, Top, Right, Bottom]
Global $g_aCursorLockMonitorRect[4] = [0, 0, 0, 0] ; Monitor rect saved when the lock is created
Global $g_aCursorLockClientRect[4] = [0, 0, 0, 0] ; Client rect saved when the lock is created

Global $browser = -1 ; Index for the currrently detected browser
Global $game = -1 ; Index for the currently detected game

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
		; Display a pending message
		ProcessPendingMessage()

		; ========== ========== ==========

		ProcessWindow()
		ProcessCursorLock()

		; ========== ========== ==========

		; Handle the About GUI, if it's open
		If $bAbout Then
			Local $aMsg = GUIGetMsg(1)
			_ProcessAboutMessage($aMsg[0], $aMsg[1])
		EndIf

		; ========== ========== ==========

		; Check tray
		Local $nTrayMsg = TrayGetMsg()
		Switch $nTrayMsg
			Case $trayMenuConfig
				ShowConfigWindow()
			Case $trayMenuAbout
				ShowAboutWindow()
			Case $trayMenuExit
				ExitScript()
			EndSwitch

		; ========== ========== ==========

		If $g_bCursorLocked Then
			Sleep(25)
		Else
			Sleep(50)
		EndIf

	WEnd
EndFunc

Func ExitScript()
	If $bShutdown = False Then
		If IsDeclared("configSplashMessages") And $configSplashMessages Then
			DisplayMessage("Closing Browser Cursor Lock")
		EndIf
		$bShutdown = True
		Sleep(1000)

		; Give transient GetClipCursor/ClipCursor failures a few short retries
		If $g_bCursorLocked Then
			Local $iReleaseAttempts = 0
			While $g_bCursorLocked And $iReleaseAttempts < 4
				$iReleaseAttempts += 1

				If ReleaseCursorLockIfOwned() Then ExitLoop
				If $iReleaseAttempts < 4 Then Sleep(25)
			WEnd
		EndIf

		If $g_bCursorLocked Then
			MsgBox(48, "Cursor Lock Warning", "Browser Cursor Lock could not verify that its cursor restriction was released before shutdown.")
		EndIf

		; Clean up message GUI and resources
		ClearMessage(True)

		; Free the reusable timer callback
		If $hClearMessageCallback <> 0 And $iClearMessageID = 0 Then
			DllCallbackFree($hClearMessageCallback)
			$hClearMessageCallback = 0
		EndIf

		; =====

		; Clean up reusable GDI+ objects

		If $g_hFont <> 0 Then
			_GDIPlus_FontDispose($g_hFont)
			$g_hFont = 0
		EndIf

		If $g_hFontFamily <> 0 Then
			_GDIPlus_FontFamilyDispose($g_hFontFamily)
			$g_hFontFamily = 0
		EndIf

		If $g_hFormat <> 0 Then
			_GDIPlus_StringFormatDispose($g_hFormat)
			$g_hFormat = 0
		EndIf

		If $g_hBrush <> 0 Then
			_GDIPlus_BrushDispose($g_hBrush)
			$g_hBrush = 0
		EndIf

		; =====

		; Shut down GDI
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

	; =====

	; Treat the Windows taskbar as a transient window
	If IsTaskbarWindow($currentHwnd) Then
		$g_bTransientWindow = True

		; Leaving the eligible browser/game target re-arms auto-lock
		$g_bAutoLockSuppressed = False
		$g_hAutoLockSuppressedHwnd = 0

		If $g_bCursorLocked Then ReleaseCursorLockIfOwned()

		Return
	EndIf

	; We are no longer in a transient window
	$g_bTransientWindow = False

	; =====

	Local $aWinPos = WinGetPos($currentHwnd) ; Cheap early error catch
	If @error Or Not IsArray($aWinPos) Then Return ; Exit if we can't get window position

	Local $currentWindow = WinGetTitle($currentHwnd)

	; =====

	; Handle other windows without a title
	If $currentWindow = "" Then
		If $g_bCursorLocked And Not ReleaseCursorLockIfOwned() Then Return

		$g_bAutoLockSuppressed = False
		$g_hAutoLockSuppressedHwnd = 0

		$browser = -1
		$game = -1
		$g_hActiveHwnd = 0

		$g_hLastHwnd = 0
		$g_sLastWindowTitle = ""

		If $currentHotkey <> "" Then
			HotKeySet($currentHotkey)
			$currentHotkey = ""
		EndIf

		Return
	EndIf

	; =====

	Local $iBrowserIndex = -1
	Local $iGameIndex = -1

	; Skip title parsing if both the handle and title remain the same
	If $currentHwnd <> $g_hLastHwnd Or $currentWindow <> $g_sLastWindowTitle Then
		; Update cached window values
		$g_hLastHwnd = $currentHwnd
		$g_sLastWindowTitle = $currentWindow

		; Find the rightmost supported title separator
		Local $lastHyphenPos = StringInStr($currentWindow, "-", 0, -1)
		Local $lastEnDashPos = StringInStr($currentWindow, "–", 0, -1)
		Local $lastEmDashPos = StringInStr($currentWindow, "—", 0, -1)

		If $lastEnDashPos > $lastHyphenPos Then $lastHyphenPos = $lastEnDashPos
		If $lastEmDashPos > $lastHyphenPos Then $lastHyphenPos = $lastEmDashPos

		; Extract browser/game names from the title
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

		If Not IsArray($g_aBrowsers) Then
			DisplayMessage("Browser config error")
			Return
		EndIf

		; Check if the window belongs to a known browser
		For $i = 0 To UBound($g_aBrowsers) - 1
			Local $browserRegex = StringStripWS($g_aBrowsers[$i][2], 3)

			; Use RegEx to match the browser title case-insensitively
			; without lowercasing the pattern itself
			If StringRegExp($titleAfterHyphen, "(?i)" & $browserRegex) Then
				$iBrowserIndex = $i
				ExitLoop
			EndIf
		Next

		; Check if the window belongs to a known game
		If $iBrowserIndex <> -1 And $titleBeforeHyphen <> "" And IsArray($g_aGames) Then
			For $i = 0 To UBound($g_aGames) - 1
				Local $gameRegex = StringStripWS($g_aGames[$i][2], 3)

				; Match case-insensitively without modifying regex tokens
				If StringRegExp($titleBeforeHyphen, "(?i)" & $gameRegex) Then
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

	; =====

	Local $sMessageText = ""

	; Handle browser activation state if a browser is detected
	If $iBrowserIndex <> -1 Then
		If $browser = -1 Or $browser <> $iBrowserIndex Then
			$browser = $iBrowserIndex
			$sMessageText = $configBrowserMessages ? $g_aBrowsers[$iBrowserIndex][1] & " Browser activated" : ""

			If $configLockCursorAllTitles Or _
				($configAutoLockFullscreenBrowsers And $configLockCursorFullscreen) Then
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
				; Any active lock may contain game-specific offsets
				; Release it before changing games so automatic locks can rebuild and manual
				; locks do not retain a clipping rectangle calculated for the previous game
				If $g_bCursorLocked And Not ReleaseCursorLockIfOwned() Then
					$g_sLastWindowTitle = "" ; Force detection/release to retry next cycle
					Return
				EndIf

				$game = $iGameIndex
				$g_hActiveHwnd = $currentHwnd

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
			If $g_hActiveHwnd <> $currentHwnd Then
				$g_hActiveHwnd = $currentHwnd

				If $configGameMessages Then
					If $sMessageText <> "" Then
						$sMessageText &= " & game detected: " & $g_aGames[$iGameIndex][1]
					Else
						$sMessageText = "Game detected: " & $g_aGames[$iGameIndex][1]
					EndIf
				EndIf
			EndIf
		Else
			If $game >= 0 Then
				; Any lock created while a game was active may contain game offsets
				; Release it before clearing the game; Browser auto-lock can immediately
				; rebuild below with browser-only offsets if fullscreen still applies
				Local $bHadGameCursorLock = $g_bCursorLocked
				Local $bWasBrowserAutoLock = $g_bCursorAutoLocked And $configAutoLockFullscreenBrowsers
				If $bHadGameCursorLock And Not ReleaseCursorLockIfOwned() Then
					$g_sLastWindowTitle = "" ; Force detection/release to retry next cycle
					Return
				EndIf

				$game = -1
				$g_hActiveHwnd = 0

				If _
					$currentHotkey <> "" And _
					Not $configLockCursorAllTitles And _
					Not ($configAutoLockFullscreenBrowsers And $configLockCursorFullscreen) _
				Then
					HotKeySet($currentHotkey)
					$currentHotkey = ""
				EndIf

				If $configGameMessages Then
					$sMessageText = "Game deactivated"
					If $bHadGameCursorLock And Not $bWasBrowserAutoLock Then _
						$sMessageText &= " and cursor unlocked"
				EndIf
			EndIf
		EndIf
	Else
		If $browser <> -1 Then
			Local $bHadBrowserCursorLock = $g_bCursorLocked
			If $bHadBrowserCursorLock And Not ReleaseCursorLockIfOwned() Then
				$g_sLastWindowTitle = "" ; Force detection/release to retry next cycle
				Return
			EndIf

			$browser = -1
			$game = -1
			$g_hActiveHwnd = 0

			$g_bAutoLockSuppressed = False
			$g_hAutoLockSuppressedHwnd = 0

			If $currentHotkey <> "" Then
				HotKeySet($currentHotkey)
				$currentHotkey = ""
			EndIf

			If $configBrowserMessages Then
				$sMessageText = "Browser deactivated"

				If $bHadBrowserCursorLock Then _
					$sMessageText &= " and cursor unlocked"
			EndIf
		EndIf
	EndIf

	If $sMessageText <> "" Then DisplayMessage($sMessageText)

	; Auto-lock acquisition belongs to window processing so it can reuse the
	; active HWND and WinGetPos result already obtained above
	TryAutoLock($currentHwnd, $aWinPos)
EndFunc

Func TryAutoLock($hWnd, ByRef $aWindow)
	; Auto-lock only applies to fullscreen locking
	Local $bAutoEnabled = $configLockCursorFullscreen And _
		($configAutoLockFullscreenGames Or $configAutoLockFullscreenBrowsers)

	If Not $bAutoEnabled Then
		$g_bAutoLockSuppressed = False
		$g_hAutoLockSuppressedHwnd = 0
		Return
	EndIf

	; A recognized browser is required for either auto-lock mode
	If $browser = -1 Or Not $hWnd Or Not WinExists($hWnd) Then
		$g_bAutoLockSuppressed = False
		$g_hAutoLockSuppressedHwnd = 0
		Return
	EndIf

	; Browser mode includes every recognized browser tab. Game mode only
	; applies while a configured game title is detected
	Local $bEligible = $configAutoLockFullscreenBrowsers Or _
		($configAutoLockFullscreenGames And $game <> -1)

	If Not $bEligible Then
		$g_bAutoLockSuppressed = False
		$g_hAutoLockSuppressedHwnd = 0
		Return
	EndIf

	; Switching to a different eligible window starts a new auto-lock cycle
	If $g_bAutoLockSuppressed And $g_hAutoLockSuppressedHwnd <> $hWnd Then
		$g_bAutoLockSuppressed = False
		$g_hAutoLockSuppressedHwnd = 0
	EndIf

	; Existing locks are maintained by ProcessCursorLock
	If $g_bCursorLocked Or $bHotkeyLock Then Return

	; Reuse the window rectangle ProcessWindow() already retrieved
	; First fetch the monitor and reject obviously windowed/maximized
	; windows before paying for a client-area query
	Local $aMonitor = WindowMonitor($hWnd)
	If @error Or Not IsArray($aMonitor) Then Return

	If $aWindow[0] <> $aMonitor[0] Or _
		$aWindow[1] <> $aMonitor[1] Or _
		$aWindow[2] <> $aMonitor[2] Or _
		$aWindow[3] <> $aMonitor[3] Then

		; Leaving fullscreen rearms a manual auto-lock override
		$g_bAutoLockSuppressed = False
		$g_hAutoLockSuppressedHwnd = 0
		Return
	EndIf

	; The outer rectangle matches the monitor; verify the client rectangle
	; to distinguish true browser fullscreen from borderless/maximized states
	Local $aClientRect = WindowClientRect($hWnd)
	If @error Or Not IsArray($aClientRect) Then Return

	If Not IsWindowFullscreen($aWindow, $aMonitor, $aClientRect) Then
		; Leaving fullscreen rearms a manual auto-lock override
		$g_bAutoLockSuppressed = False
		$g_hAutoLockSuppressedHwnd = 0
		Return
	EndIf

	; A manual unlock suppresses auto-lock only for this fullscreen window
	If $g_bAutoLockSuppressed And $g_hAutoLockSuppressedHwnd = $hWnd Then Return

	; Use the geometry already gathered above so LockCursor() does not repeat
	; WinGetPos/monitor/client queries. Suppress repeated retries for this
	; fullscreen cycle if the actual ClipCursor operation fails.
	If Not LockCursorWithGeometry($hWnd, $aWindow, $aMonitor, $aClientRect, True) Then
		$g_bAutoLockSuppressed = True
		$g_hAutoLockSuppressedHwnd = $hWnd
	EndIf
EndFunc

Func WindowBorders()
	Local $aBorders = GetWindowBorders()
	If @error Or Not IsArray($aBorders) Then Return SetError(1, 0, 0)

	Local $aWindowBorders[4] = [ _
		$aBorders[0], _
		$aBorders[1], _
		$aBorders[0], _
		$aBorders[1] _
	]

	; [0] = Top
	; [1] = Right
	; [2] = Bottom
	; [3] = Left
	Return $aWindowBorders
EndFunc

Func WindowClient($aWindow, $aBorders)
	If Not IsArray($aWindow) Or UBound($aWindow) < 4 Then Return SetError(1, 0, 0)
	If Not IsArray($aBorders) Or UBound($aBorders) < 4 Then Return SetError(2, 0, 0)

	Local $aClient[4] = [ _
		$aWindow[0] + $aBorders[3], _
		$aWindow[1] + $aBorders[0], _
		$aWindow[2] - ($aBorders[3] + $aBorders[1]), _
		$aWindow[3] - ($aBorders[0] + $aBorders[2]) _
	]

	Return $aClient
EndFunc

Func WindowClientRect($hWnd)
	Local $tClientRect = _WinAPI_GetClientRect($hWnd)
	If @error Then Return SetError(1, 0, 0)

	Local $iWidth = DllStructGetData($tClientRect, 3)
	Local $iHeight = DllStructGetData($tClientRect, 4)

	Local $tPoint = DllStructCreate("int X; int Y")
	DllStructSetData($tPoint, "X", 0)
	DllStructSetData($tPoint, "Y", 0)

	_WinAPI_ClientToScreen($hWnd, DllStructGetPtr($tPoint))
	If @error Then Return SetError(2, 0, 0)

	Local $aClientRect[4] = [ _
		DllStructGetData($tPoint, "X"), _
		DllStructGetData($tPoint, "Y"), _
		$iWidth, _
		$iHeight _
	]

	Return $aClientRect
EndFunc

Func WindowMonitor($hWnd)
	; Validate window
	If Not $hWnd Or Not WinExists($hWnd) Then Return SetError(1, 0, 0)

	; Get the monitor with the largest intersection with the window
	Local $hMonitor = _WinAPI_MonitorFromWindow($hWnd)
	If Not $hMonitor Then Return SetError(2, 0, 0)

	; Get monitor information
	Local $aMonitorInfo = _WinAPI_GetMonitorInfo($hMonitor)
	If @error Or Not IsArray($aMonitorInfo) Then Return SetError(3, 0, 0)

	; Get monitor rectangle
	Local $iLeft = DllStructGetData($aMonitorInfo[0], "Left")
	Local $iTop = DllStructGetData($aMonitorInfo[0], "Top")
	Local $iRight = DllStructGetData($aMonitorInfo[0], "Right")
	Local $iBottom = DllStructGetData($aMonitorInfo[0], "Bottom")

	Local $aMonitor[4] = [ _
		$iLeft, _
		$iTop, _
		$iRight - $iLeft, _
		$iBottom - $iTop _
	]

	; [0] = X
	; [1] = Y
	; [2] = Width
	; [3] = Height
	Return $aMonitor
EndFunc

Func WindowPosition($hWnd)
	Local $aWinPos = WinGetPos($hWnd)
	If @error Or Not IsArray($aWinPos) Or UBound($aWinPos) < 4 Then _
		Return SetError(1, 0, 0)
	Return $aWinPos
EndFunc

Func IsWindowFullscreen($aWindow, $aMonitor, $aClientRect)
	If $aWindow[0] = $aMonitor[0] And _
		$aWindow[1] = $aMonitor[1] And _
		$aWindow[2] = $aMonitor[2] And _
		$aWindow[3] = $aMonitor[3] And _
		$aClientRect[0] = $aMonitor[0] And _
		$aClientRect[1] = $aMonitor[1] And _
		$aClientRect[2] = $aMonitor[2] And _
		$aClientRect[3] = $aMonitor[3] Then

		Return True
	EndIf

	Return False
EndFunc

Func IsTaskbarWindow($hWnd)
	Local $sClass = _WinAPI_GetClassName($hWnd)
	If @error Or $sClass = "" Then Return False

	Return $sClass = "Shell_TrayWnd" Or _
		$sClass = "Shell_SecondaryTrayWnd"
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
	If Not $hDC Then Return SetError(1, 0, 96)

	Local $aDPI
	If @AutoItX64 Then
		$aDPI = DllCall("gdi32.dll", "int", "GetDeviceCaps", "ptr", $hDC, "int", 88)
	Else
		$aDPI = DllCall("gdi32.dll", "int", "GetDeviceCaps", "hwnd", $hDC, "int", 88)
	EndIf
	Local $iCallError = @error

	; 88 = LOGPIXELSX
	_WinAPI_ReleaseDC(0, $hDC)

	If $iCallError Or Not IsArray($aDPI) Or $aDPI[0] <= 0 Then Return SetError(2, 0, 96)
	Return $aDPI[0]
EndFunc

#EndRegion
; =====

; ========== ========== ========== ========== ==========

; =====
#Region CursorLock

Func ToggleCursorLock()
	; Prevent toggle on transient window
	If $g_bTransientWindow Then Return

	; Prevent multiple presses
	If $bHotkeyLock Then Return
	$bHotkeyLock = True

	; Unset the old hotkey
	; If $currentHotkey <> "" Then HotKeySet($currentHotkey)

	; If already locked, unlock it
	If $g_bCursorLocked Then
		; Remember an explicit manual unlock so auto-lock does not immediately
		; lock the same fullscreen window again on the next processing cycle
		If $configLockCursorFullscreen And _
			($configAutoLockFullscreenGames Or $configAutoLockFullscreenBrowsers) Then
			$g_bAutoLockSuppressed = True
			$g_hAutoLockSuppressedHwnd = $g_hCursorLockHwnd
		EndIf

		If Not ReleaseCursorLockIfOwned() Then
			; The current system clip could not be read, so leave the lock intact
			; and allow the user or the normal processing loop to retry
			$g_bAutoLockSuppressed = False
			$g_hAutoLockSuppressedHwnd = 0
			DisplayMessage("Unable to verify cursor release")
			Sleep(5)
			$bHotkeyLock = False
			Return
		EndIf

		DisplayMessage("Cursor unlocked")
		Sleep(5)
		$bHotkeyLock = False
		Return
	EndIf

	; Ensure the current detection state permits a manual lock
	; Browser fullscreen auto-lock keeps the hotkey available for manual
	; override, but it must not broaden ordinary windowed browser locking
	Local $bBrowserAutoManualOverride = False

	If Not $configLockCursorAllTitles Then
		; A detected game keeps the existing manual game-lock behavior
		If $g_hActiveHwnd <> 0 And WinExists($g_hActiveHwnd) Then
			; Nothing else to validate here
		ElseIf $configAutoLockFullscreenBrowsers And $configLockCursorFullscreen And _
			$browser <> -1 And $g_hLastHwnd <> 0 And WinExists($g_hLastHwnd) Then

			$bBrowserAutoManualOverride = True
		Else
			DisplayMessage("No active game window detected")
			Sleep(5)
			$bHotkeyLock = False
			Return
		EndIf
	EndIf

	; Retrieve the window selected by the current detection state
	Local $hWnd = 0
	If $g_hActiveHwnd <> 0 Then
		$hWnd = $g_hActiveHwnd
	ElseIf $g_hLastHwnd <> 0 Then
		$hWnd = $g_hLastHwnd
	EndIf

	If Not WinExists($hWnd) Then
		DisplayMessage("Selected window not found")
		Sleep(5)
		$bHotkeyLock = False
		Return
	EndIf

	; Browser auto-lock's manual exception is fullscreen-only
	If $bBrowserAutoManualOverride Then
		Local $aManualWindow = WindowPosition($hWnd)
		Local $aManualMonitor = WindowMonitor($hWnd)
		Local $aManualClient = WindowClientRect($hWnd)

		If @error Or Not IsArray($aManualWindow) Or Not IsArray($aManualMonitor) Or _
			Not IsArray($aManualClient) Or _
			Not IsWindowFullscreen($aManualWindow, $aManualMonitor, $aManualClient) Then

			DisplayMessage("Browser auto-lock manual override requires fullscreen")
			Sleep(5)
			$bHotkeyLock = False
			Return
		EndIf
	EndIf

	; =====

	; A deliberate manual lock starts a fresh cycle
	$g_bAutoLockSuppressed = False
	$g_hAutoLockSuppressedHwnd = 0

	LockCursor($hWnd)

	Sleep(5)
	$bHotkeyLock = False
EndFunc

Func LockCursor($hWnd, $bAuto = False)
	If Not $hWnd Or Not WinExists($hWnd) Then
		If Not $bAuto Then DisplayMessage("Selected window not found")
		Return SetError(1, 0, False)
	EndIf

	; Get window position
	Local $aWindow = WindowPosition($hWnd)
	If @error Or Not IsArray($aWindow) Then
		If Not $bAuto Then DisplayMessage("Failed to detect window position")
		Return SetError(2, 0, False)
	EndIf

	; Get monitor containing the window
	Local $aMonitor = WindowMonitor($hWnd)
	If @error Or Not IsArray($aMonitor) Then
		If Not $bAuto Then DisplayMessage("Failed to detect window monitor")
		Return SetError(3, 0, False)
	EndIf

	; Get actual client rectangle
	Local $aClientRect = WindowClientRect($hWnd)
	If @error Or Not IsArray($aClientRect) Then
		If Not $bAuto Then DisplayMessage("Failed to detect window client area")
		Return SetError(4, 0, False)
	EndIf

	Return LockCursorWithGeometry($hWnd, $aWindow, $aMonitor, $aClientRect, $bAuto)
EndFunc

Func LockCursorWithGeometry($hWnd, ByRef $aWindow, ByRef $aMonitor, ByRef $aClientRect, $bAuto = False)
	If $g_bCursorLocked Then Return True
	If Not $hWnd Or Not WinExists($hWnd) Then Return SetError(1, 0, False)
	If Not IsArray($aWindow) Or Not IsArray($aMonitor) Or Not IsArray($aClientRect) Then _
		Return SetError(2, 0, False)

	; The state machine should guarantee these indexes, but validate them at the
	; final point of use so a future state/configuration bug cannot index outside an array
	If Not IsArray($g_aBrowsers) Or $browser < 0 Or $browser >= UBound($g_aBrowsers, 1) Then
		If Not $bAuto Then DisplayMessage("Browser configuration state is invalid")
		Return SetError(8, 0, False)
	EndIf

	If $game <> -1 Then
		If Not IsArray($g_aGames) Or $game < 0 Or $game >= UBound($g_aGames, 1) Then
			If Not $bAuto Then DisplayMessage("Game configuration state is invalid")
			Return SetError(9, 0, False)
		EndIf
	EndIf

	; Determine fullscreen state
	Local $bFullscreen = IsWindowFullscreen($aWindow, $aMonitor, $aClientRect)

	; An automatic request is valid only while the window is actually fullscreen.
	If $bAuto And Not $bFullscreen Then Return False

	; =====

	Local $iTop = 0, $iRight = 0, $iBottom = 0, $iLeft = 0
	Local $sSuccessMessage = ""

	; Prepare the clipping dimensions and success message
	If $bFullscreen Then
		If Not $configLockCursorFullscreen Then
			If Not $bAuto Then DisplayMessage("Fullscreen cursor lock is disabled")
			Return SetError(3, 0, False)
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

		$iTop = $aWindow[1]
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
			$sSuccessMessage = "Cursor locked to fullscreen game window"
		Else
			$sSuccessMessage = "Cursor locked to fullscreen browser window"
		EndIf
	Else
		If Not $configLockCursorWindowed Then
			DisplayMessage("Windowed cursor lock is disabled")
			Return SetError(4, 0, False)
		EndIf

		Local $aWindowBrowserOffsets = StringSplit($g_aBrowsers[$browser][3], ",", 2)
		If UBound($aWindowBrowserOffsets) <> 4 Then Local $aWindowBrowserOffsets = [0, 0, 0, 0]

		Local $aWindowGameOffsets
		If $game <> -1 Then
			$aWindowGameOffsets = StringSplit($g_aGames[$game][3], ",", 2)
			If UBound($aWindowGameOffsets) <> 4 Then Local $aWindowGameOffsets = [0, 0, 0, 0]
		Else
			$aWindowGameOffsets = False
		EndIf

		$iTop = $aClientRect[1]
		$iRight = $aClientRect[0] + $aClientRect[2]
		$iBottom = $aClientRect[1] + $aClientRect[3]
		$iLeft = $aClientRect[0]

		If IsArray($aWindowBrowserOffsets) And UBound($aWindowBrowserOffsets) = 4 Then
			$iTop += Number($aWindowBrowserOffsets[0])
			$iRight -= Number($aWindowBrowserOffsets[1])
			$iBottom -= Number($aWindowBrowserOffsets[2])
			$iLeft += Number($aWindowBrowserOffsets[3])
		EndIf

		If IsArray($aWindowGameOffsets) And UBound($aWindowGameOffsets) = 4 Then
			$iTop += Number($aWindowGameOffsets[0])
			$iRight -= Number($aWindowGameOffsets[1])
			$iBottom -= Number($aWindowGameOffsets[2])
			$iLeft += Number($aWindowGameOffsets[3])
		EndIf

		If $game <> -1 Then
			$sSuccessMessage = "Cursor locked to game window"
		Else
			$sSuccessMessage = "Cursor locked to browser window"
		EndIf
	EndIf

	; Protect against bad offsets and values that cannot fit a Win32 RECT LONG
	If $iRight <= $iLeft Or $iBottom <= $iTop Or _
		Not _IsInt32Value($iTop) Or Not _IsInt32Value($iRight) Or _
		Not _IsInt32Value($iBottom) Or Not _IsInt32Value($iLeft) Then

		DisplayMessage("Invalid cursor lock rectangle")
		Return SetError(5, 0, False)
	EndIf

	; Create the clipping rectangle
	Local $tRect = _WinAPI_CreateRect($iLeft, $iTop, $iRight, $iBottom)
	If @error Then
		DisplayMessage("Failed to create rectangle structure")
		Return SetError(6, 0, False)
	EndIf

	; Apply cursor restriction
	Local $aResult = DllCall("user32.dll", "bool", "ClipCursor", "ptr", DllStructGetPtr($tRect))

	If @error Or Not IsArray($aResult) Or Not $aResult[0] Then
		DisplayMessage("Failed to clip cursor")
		$g_bCursorLocked = False
		Return SetError(7, 0, False)
	EndIf

	; =====

	; Store the window this cursor lock belongs to
	$g_hCursorLockHwnd = $hWnd

	; Store the exact clipping rectangle
	$g_aCursorClipRect[0] = $iLeft
	$g_aCursorClipRect[1] = $iTop
	$g_aCursorClipRect[2] = $iRight
	$g_aCursorClipRect[3] = $iBottom

	; Only mark as locked after ClipCursor succeeds
	$g_bCursorLocked = True
	$g_bCursorAutoLocked = $bAuto

	; Store the geometry used to create this lock for change tracking
	For $i = 0 To 3
		$g_aBrowserRect[$i] = $aWindow[$i]
		$g_aCursorLockMonitorRect[$i] = $aMonitor[$i]
		$g_aCursorLockClientRect[$i] = $aClientRect[$i]
	Next

	; Only announce success after ClipCursor actually succeeded
	If $sSuccessMessage <> "" Then DisplayMessage($sSuccessMessage)

	Return True
EndFunc

Func ProcessCursorLock()
	; Nothing to monitor
	If Not $g_bCursorLocked Then Return

	Local $tCurrentClip
	Local $bWasAutoLocked = False

	; =====

	; Make sure the lock's owner still exists
	If $g_hCursorLockHwnd = 0 Or Not WinExists($g_hCursorLockHwnd) Then
		ReleaseCursorLockIfOwned()
		Return
	EndIf

	; =====

	; Make sure the lock's owner is still the active window
	Local $hCurrentWnd = WinGetHandle("[ACTIVE]")
	If @error Or $hCurrentWnd = 0 Then Return

	If $hCurrentWnd <> $g_hCursorLockHwnd Then
		If Not ReleaseCursorLockIfOwned() Then Return
		DisplayMessage("Cursor Released")
		Return
	EndIf

	; =====

	; Check whether the locked window has moved or resized
	Local $aWinPos = WindowPosition($g_hCursorLockHwnd)

	If @error Or Not IsArray($aWinPos) Then
		If Not ReleaseCursorLockIfOwned() Then Return
		DisplayMessage("Cursor Released")
		Return
	EndIf

	If $aWinPos[0] <> $g_aBrowserRect[0] Or _
		$aWinPos[1] <> $g_aBrowserRect[1] Or _
		$aWinPos[2] <> $g_aBrowserRect[2] Or _
		$aWinPos[3] <> $g_aBrowserRect[3] Then

		$bWasAutoLocked = $g_bCursorAutoLocked
		If Not ReleaseCursorLockIfOwned() Then Return

		If $bWasAutoLocked Then
			$g_bAutoLockSuppressed = False
			$g_hAutoLockSuppressedHwnd = 0
		EndIf

		DisplayMessage("Cursor Released")
		Return
	EndIf

	; =====

	; The clipping rectangle depends on the client geometry as well as the
	; outer window. Browser UI/F11 changes can alter the client area without
	; changing WinGetPos(), so monitor it for both manual and automatic locks.
	Local $aClientRect = WindowClientRect($g_hCursorLockHwnd)
	If @error Or Not IsArray($aClientRect) Then
		If Not ReleaseCursorLockIfOwned() Then Return
		DisplayMessage("Cursor Released")
		Return
	EndIf

	If $aClientRect[0] <> $g_aCursorLockClientRect[0] Or _
		$aClientRect[1] <> $g_aCursorLockClientRect[1] Or _
		$aClientRect[2] <> $g_aCursorLockClientRect[2] Or _
		$aClientRect[3] <> $g_aCursorLockClientRect[3] Then

		$bWasAutoLocked = $g_bCursorAutoLocked
		If Not ReleaseCursorLockIfOwned() Then Return

		If $bWasAutoLocked Then
			; A geometry/fullscreen transition starts a new auto-lock cycle
			$g_bAutoLockSuppressed = False
			$g_hAutoLockSuppressedHwnd = 0
		EndIf

		DisplayMessage("Cursor Released")
		Return
	EndIf

	; =====

	; Automatic locks remain active only while their fullscreen eligibility remains true
	If $g_bCursorAutoLocked Then
		Local $bAutoEligible = $configLockCursorFullscreen And $browser <> -1 And _
			($configAutoLockFullscreenBrowsers Or _
			($configAutoLockFullscreenGames And $game <> -1))

		Local $bReleaseAutoLock = Not $bAutoEligible

		If Not $bReleaseAutoLock And _
			Not IsWindowFullscreen($aWinPos, $g_aCursorLockMonitorRect, $aClientRect) Then
			$bReleaseAutoLock = True
		EndIf

		If $bReleaseAutoLock Then
			If Not ReleaseCursorLockIfOwned() Then Return

			; Automatic release rearms the next fullscreen entry
			$g_bAutoLockSuppressed = False
			$g_hAutoLockSuppressedHwnd = 0
			DisplayMessage("Cursor Released")
			Return
		EndIf
	EndIf

	; =====

	; Get the clipping rectangle Windows is currently enforcing
	$tCurrentClip = _WinAPI_GetClipCursor()
	If @error Then Return

	; Nothing changed
	If DllStructGetData($tCurrentClip, "Left") = $g_aCursorClipRect[0] And _
		DllStructGetData($tCurrentClip, "Top") = $g_aCursorClipRect[1] And _
		DllStructGetData($tCurrentClip, "Right") = $g_aCursorClipRect[2] And _
		DllStructGetData($tCurrentClip, "Bottom") = $g_aCursorClipRect[3] Then

		Return
	EndIf

	; =====

	; The system clip changed underneath us
	; Recreate and restore our expected rectangle
	Local $tExpectedClip = _WinAPI_CreateRect( _
		$g_aCursorClipRect[0], _
		$g_aCursorClipRect[1], _
		$g_aCursorClipRect[2], _
		$g_aCursorClipRect[3] _
	)

	If @error Then Return

	If Not _WinAPI_ClipCursor($tExpectedClip) Then
		; Our expected clip is no longer active and restoration failed
		; Clear our state without releasing somebody else's clip
		ResetCursorLock(False)
	EndIf
EndFunc

Func ReleaseCursorLockIfOwned()
	If Not $g_bCursorLocked Then Return True

	; If the current system clip cannot be read, we cannot safely determine ownership
	; Leave our state intact so the next processing cycle can retry
	Local $tCurrentClip = _WinAPI_GetClipCursor()
	If @error Then Return False

	; ClipCursor is shared system state and we should only release it if Windows
	; is still enforcing the exact rectangle this program installed
	Local $bOwned = _
		DllStructGetData($tCurrentClip, "Left") = $g_aCursorClipRect[0] And _
		DllStructGetData($tCurrentClip, "Top") = $g_aCursorClipRect[1] And _
		DllStructGetData($tCurrentClip, "Right") = $g_aCursorClipRect[2] And _
		DllStructGetData($tCurrentClip, "Bottom") = $g_aCursorClipRect[3]

	; If another component already replaced our clip, clear only our bookkeeping
	If Not $bOwned Then
		ResetCursorLock(False)
		Return True
	EndIf

	; We still own the exact system clip. Only clear bookkeeping if Windows
	; actually accepts the release; otherwise keep state intact for a retry.
	Return ResetCursorLock(True)
EndFunc

Func ResetCursorLock($bReleaseCursor = True)
	If Not $g_bCursorLocked Then Return True

	If $bReleaseCursor Then
		If Not _WinAPI_ClipCursor(0) Then Return SetError(1, 0, False)
	EndIf

	$g_bCursorLocked = False
	$g_bCursorAutoLocked = False
	$g_hCursorLockHwnd = 0

	For $i = 0 To 3
		$g_aBrowserRect[$i] = 0
		$g_aCursorClipRect[$i] = 0
		$g_aCursorLockMonitorRect[$i] = 0
		$g_aCursorLockClientRect[$i] = 0
	Next

	$bHotkeyLock = False
	Return True
EndFunc

#EndRegion
; =====

; ========== ========== ========== ========== ==========

; =====
#Region DisplayMessage

Global Const $GDIP_TEXTRENDERINGHINT_ANTIALIASGRIDFIT = 3 ; Specifies that a character is drawn using its antialiased glyph bitmap and hinting

Global $hGDIP = 0
Global $hGUI = 0

; ==

; Reusable GDI+
Global $g_hBrush = 0
Global $g_hFormat = 0

Global $g_hFontFamily = 0
Global $g_hFont = 0

Global $g_sFontName = ""
Global $g_iFontSize = 0

; ==

Global $g_hGraphic = 0

Global $g_iMessagePadding = 10
Global $g_iMessageOpacity = -1
Global $iMessageTimer
Global $iMessageDuration = 0

Global $bMessageLock = False
Global $bMessagePending = False
Global $g_aCurrentMessage

Global $hClearMessageCallback = 0
Global $bCallbackLock = False

Global $iClearMessageID = 0

Func UpdateMessageFont($sFontName, $iFontSize)

	; Nothing changed
	If $g_hFont <> 0 And _
		$g_sFontName = $sFontName And _
		$g_iFontSize = $iFontSize Then

		Return True
	EndIf

	; Font object depends on both family and size
	If $g_hFont <> 0 Then
		_GDIPlus_FontDispose($g_hFont)
		$g_hFont = 0
	EndIf

	; Family only depends on font name
	If $g_hFontFamily <> 0 And $g_sFontName <> $sFontName Then
		_GDIPlus_FontFamilyDispose($g_hFontFamily)
		$g_hFontFamily = 0
	EndIf

	; Create family if necessary
	If $g_hFontFamily = 0 Then
		$g_hFontFamily = _GDIPlus_FontFamilyCreate($sFontName)
		If @error Or $g_hFontFamily = 0 Then _
			Return SetError(1, 0, False)
	EndIf

	; Create font
	$g_hFont = _GDIPlus_FontCreate($g_hFontFamily, $iFontSize, 0)
	If @error Or $g_hFont = 0 Then _
		Return SetError(2, 0, False)

	; Cache identity
	$g_sFontName = $sFontName
	$g_iFontSize = $iFontSize

	Return True
EndFunc

Func DisplayMessage($sText, $iDuration = $configDuration, $sFontName = $configFont, $iFontSize = $configFontSize, $iOpacity = $configOpacity)
	; Update the global message parameters
	Local $aMessage[5] = [$sText, $iDuration, $sFontName, $iFontSize, $iOpacity]
	$g_aCurrentMessage = $aMessage

	; =====

	; If an update is already in progress, defer the new message
	If $bMessageLock Or $bCallbackLock Then
		$bMessagePending = True
		Return
	EndIf

	; Otherwise, acquire the lock
	$bMessageLock = True

	; =====

	Local Const $LWA_ALPHA = 0x00000002
	Local Const $SWP_NOZORDER = 0x0004
	Local Const $SWP_NOACTIVATE = 0x0010

	ClearMessageTimerStop()

	; Loop to catch any pending updates that might have come in during processing
	Do
		; Clear the pending flag
		$bMessagePending = False

		; Make a local copy of the current message data
		Local $aLocalMessage = $g_aCurrentMessage

		; Use the local copy for all further processing
		Local $sLocalText = StringStripWS($aLocalMessage[0], 3)
		Local $iLocalOpacity = $aLocalMessage[4]

		; Update reusable font resources if necessary
		If Not UpdateMessageFont($aLocalMessage[2], $aLocalMessage[3]) Then
			Return _DisplayMessageFail(8, @error)
		EndIf

		; Calculate text dimensions using the reusable font
		Local $aTextSize = _StringInPixelsNoGUI($sLocalText, $g_hFont)
		If @error Or Not IsArray($aTextSize) Then
			; Failed to set text dimensions
			Return _DisplayMessageFail(5)
		EndIf

		Local $iTextWidth = Ceiling($aTextSize[0]) + 3 + ($g_iMessagePadding * 2)
		Local $iTextHeight = Ceiling($aTextSize[1]) + ($g_iMessagePadding * 2)

		; Get active window handle
		Local $hWnd = WinGetHandle("[ACTIVE]")
		If @error Then $hWnd = 0

		; Get monitor containing the active window
		Local $aRect = WindowMonitor($hWnd)

		If @error Or Not IsArray($aRect) Then
			Local $aDefaultRect[4] = [0, 0, @DesktopWidth, @DesktopHeight] ; Default values
			$aRect = $aDefaultRect
		EndIf

		; Calculate message position centered on detected monitor
		Local $iMessageX = $aRect[0] + (($aRect[2] - $iTextWidth) / 2)
		Local $iMessageY = $aRect[1] + (($aRect[3] - $iTextHeight) / 2)

		; Results for window settings
		Local $aResult

		; Create GUI
		If $hGUI = 0 Then
			$hGUI = GUICreate("Browser Cursor Lock", _
				$iTextWidth, _
				$iTextHeight, _
				$iMessageX, _
				$iMessageY, _
				$WS_POPUP, _
				BitOR($WS_EX_TOPMOST, $WS_EX_LAYERED, $WS_EX_TOOLWINDOW, $WS_EX_NOACTIVATE) _
			)

			If @error Or $hGUI = 0 Then
				; Failed to create the GUI
				Return _DisplayMessageFail(6)
			EndIf

			If @AutoItX64 Then
				$aResult = DllCall("user32.dll", _
					"ptr", "SetWindowLongPtr", _
					"hwnd", $hGUI, _
					"int", $GWL_EXSTYLE, _
					"ptr", BitOR($WS_EX_NOACTIVATE, $WS_EX_TOOLWINDOW, $WS_EX_TRANSPARENT, $WS_EX_LAYERED) _
				)
			Else
				$aResult = DllCall("user32.dll", _
					"long", "SetWindowLong", _
					"hwnd", $hGUI, _
					"int", $GWL_EXSTYLE, _
					"long", BitOR($WS_EX_NOACTIVATE, $WS_EX_TOOLWINDOW, $WS_EX_TRANSPARENT, $WS_EX_LAYERED) _
				)
			EndIf

			If @error Or Not IsArray($aResult) Then
				; Failed to call the window-style API
				Return _DisplayMessageFail(7)
			EndIf

			; Set opacity
			If @AutoItX64 Then
				$aResult = DllCall("user32.dll", _
					"bool", "SetLayeredWindowAttributes", _
					"ptr", $hGUI, _
					"dword", 0, _
					"byte", $iLocalOpacity, _
					"dword", $LWA_ALPHA _
				)
			Else
				$aResult = DllCall("user32.dll", "bool", "SetLayeredWindowAttributes", _
					"hwnd", $hGUI, _
					"dword", 0, _
					"byte", $iLocalOpacity, _
					"dword", $LWA_ALPHA _
				)
			EndIf

			If Not @error And IsArray($aResult) And $aResult[0] Then
				$g_iMessageOpacity = $iLocalOpacity
			EndIf

			WinSetOnTop($hGUI, "", 1)
			GUISetState(@SW_SHOWNA, $hGUI)
		Else
			; Move existing message window
			DllCall("user32.dll", _
				"bool", "SetWindowPos", _
				"hwnd", $hGUI, _
				"hwnd", 0, _
				"int", $iMessageX, _
				"int", $iMessageY, _
				"int", $iTextWidth + 100, _
				"int", $iTextHeight, _
				"uint", BitOR($SWP_NOZORDER, $SWP_NOACTIVATE) _
			)

			; Update opacity only if it changed
			If $g_iMessageOpacity <> $iLocalOpacity Then
				If @AutoItX64 Then
					$aResult = DllCall("user32.dll", _
						"bool", "SetLayeredWindowAttributes", _
						"ptr", $hGUI, _
						"dword", 0, _
						"byte", $iLocalOpacity, _
						"dword", $LWA_ALPHA _
					)
				Else
					$aResult = DllCall("user32.dll", "bool", "SetLayeredWindowAttributes", _
						"hwnd", $hGUI, _
						"dword", 0, _
						"byte", $iLocalOpacity, _
						"dword", $LWA_ALPHA _
					)
				EndIf

				If Not @error And IsArray($aResult) And $aResult[0] Then
					$g_iMessageOpacity = $iLocalOpacity
				EndIf
			EndIf

			; Clear the existing drawing
			If $g_hGraphic <> 0 Then
				_GDIPlus_GraphicsClear($g_hGraphic)
				_GDIPlus_GraphicsDispose($g_hGraphic)
				$g_hGraphic = 0
			EndIf

			_WinAPI_RedrawWindow($hGUI, 0, 0, BitOR($RDW_INVALIDATE, $RDW_UPDATENOW))
		EndIf

		$g_hGraphic = _GDIPlus_GraphicsCreateFromHWND($hGUI)
		If @error Or $g_hGraphic = 0 Then
			$g_hGraphic = 0
			Return _DisplayMessageFail(12)
		EndIf

		_GDIPlus_GraphicsSetTextRenderingHint($g_hGraphic, $GDIP_TEXTRENDERINGHINT_ANTIALIASGRIDFIT)

		; ==========

		If $g_hBrush = 0 Then
			$g_hBrush = _GDIPlus_BrushCreateSolid(0x7F000000)
			If @error Or $g_hBrush = 0 Then
				$g_hBrush = 0
				Return _DisplayMessageFail(1)
			EndIf
		EndIf

		If $g_hFormat = 0 Then
			$g_hFormat = _GDIPlus_StringFormatCreate()
			If @error Or $g_hFormat = 0 Then
				$g_hFormat = 0
				Return _DisplayMessageFail(2)
			EndIf

			; =====

			Local $aRet = DllCall("gdiplus.dll", _
				"int", "GdipSetStringFormatAlign", _
				"ptr", $g_hFormat, _
				"int", 0 _
			)

			If @error Or Not IsArray($aRet) Then
				_GDIPlus_StringFormatDispose($g_hFormat)
				$g_hFormat = 0
				Return _DisplayMessageFail(3)
			EndIf
			If $aRet[0] <> 0 Then
				_GDIPlus_StringFormatDispose($g_hFormat)
				$g_hFormat = 0
				Return _DisplayMessageFail(3, $aRet[0])
			EndIf

			$aRet = DllCall("gdiplus.dll", _
				"int", "GdipSetStringFormatFlags", _
				"ptr", $g_hFormat, _
				"int", 0 _
			)

			If @error Or Not IsArray($aRet) Then
				_GDIPlus_StringFormatDispose($g_hFormat)
				$g_hFormat = 0
				Return _DisplayMessageFail(4)
			EndIf
			If $aRet[0] <> 0 Then
				_GDIPlus_StringFormatDispose($g_hFormat)
				$g_hFormat = 0
				Return _DisplayMessageFail(4, $aRet[0])
			EndIf

			; =====

		EndIf

		; ==========

		Local $tLayout = _GDIPlus_RectFCreate( _
			$g_iMessagePadding - 3, _
			$g_iMessagePadding, _
			$aTextSize[0] + 100, _
			$aTextSize[1] _
		)

		Local $hRegion = _WinAPI_CreateRoundRectRgn( _
			0, _
			0, _
			$iTextWidth, _
			$iTextHeight, _
			$g_iMessagePadding * 2, _
			$g_iMessagePadding * 2 _
		)

		If Not $hRegion Then
			Return _DisplayMessageFail(9)
		EndIf

		_WinAPI_RedrawWindow($hGUI, 0, 0, BitOR($RDW_INVALIDATE, $RDW_UPDATENOW))

		; Draw the rounded corners
		If Not _WinAPI_SetWindowRgn($hGUI, $hRegion) Then
			; Windows did not take ownership because the call failed
			_WinAPI_DeleteObject($hRegion)

			Return _DisplayMessageFail(10)
		EndIf

		; Windows owns $hRegion from this point onward
		; Do not delete or use $hRegion again

		; Draw the updated string
		If Not _GDIPlus_GraphicsDrawStringEx( _
			$g_hGraphic, _
			$sLocalText, _
			$g_hFont, _
			$tLayout, _
			$g_hFormat, _
			$g_hBrush _
		) Then
			Return _DisplayMessageFail(16, @error)
		EndIf

		_WinAPI_RedrawWindow($hGUI, 0, 0, BitOR($RDW_INVALIDATE, $RDW_UPDATENOW))

		; Restart timer
		$iMessageDuration = $aLocalMessage[1]
		$iMessageTimer = TimerInit()

		; A short sleep to allow any potential new updates to set the pending flag
		Sleep(25)
	Until Not $bMessagePending

	If Not ClearMessageTimerStart() Then
		; Do not leave a notification stranded on screen if its auto-clear timer
		; could not be started
		Return _DisplayMessageFail(11)
	EndIf

	; Release the lock
	$bMessageLock = False
	Return True
EndFunc

Func _DisplayMessageFail($iError, $iExtended = 0)
	; Every DisplayMessage error exits through one cleanup path so a partially
	; created notification GUI or graphics handle cannot be left behind
	; Keep the message lock held until cleanup finishes so the timer callback
	; cannot enter the notification code while resources are being torn down
	ClearMessage(True)
	$bMessageLock = False

	Return SetError($iError, $iExtended, False)
EndFunc

Func ProcessPendingMessage()
	If Not $bMessagePending Or $bMessageLock Or $bCallbackLock Then Return

	DisplayMessage( _
		$g_aCurrentMessage[0], _
		$g_aCurrentMessage[1], _
		$g_aCurrentMessage[2], _
		$g_aCurrentMessage[3], _
		$g_aCurrentMessage[4] _
	)
EndFunc

Func ClearMessageTimerStart()
	; If a previous KillTimer call failed, its timer ID remains valid/unresolved
	; Do not overwrite that ID with another timer; the existing callback can
	; continue servicing the current message until it can be stopped cleanly
	If $iClearMessageID <> 0 Then Return True

	; Create the callback once and reuse it
	If $hClearMessageCallback = 0 Then
		If @AutoItX64 Then
			; 64-bit: third param must be "ptr" or "uint_ptr"
			$hClearMessageCallback = DllCallbackRegister( _
				"ClearMessageTimer", _
				"none", _
				"hwnd;uint;ptr;dword" _
			)
		Else
			; 32-bit: third param is just "uint"
			$hClearMessageCallback = DllCallbackRegister( _
				"ClearMessageTimer", _
				"none", _
				"hwnd;uint;uint;dword" _
			)
		EndIf

		If @error Or $hClearMessageCallback = 0 Then
			MsgBox(16, "Timer Error", "Failed to create the ClearMessage callback.")
			Return SetError(1, 0, False)
		EndIf
	EndIf

	; Get the reusable callback's function pointer
	Local $pCallback = DllCallbackGetPtr($hClearMessageCallback)

	If @error Or $pCallback = 0 Then
		MsgBox(16, "Timer Error", "Failed to get the ClearMessage callback pointer.")
		Return SetError(2, 0, False)
	EndIf

	; =====

	; Start a temporary Windows timer
	Local $aTimer

	If @AutoItX64 Then
		$aTimer = DllCall("user32.dll", _
			"ptr", "SetTimer", _
			"ptr", 0, _
			"ptr", 0, _
			"uint", 50, _
			"ptr", $pCallback _
		)
	Else
		$aTimer = DllCall("user32.dll", _
			"uint", "SetTimer", _
			"hwnd", 0, _
			"uint", 0, _
			"uint", 50, _
			"ptr", $pCallback _
		)
	EndIf

	If @error Or Not IsArray($aTimer) Or $aTimer[0] = 0 Then
		MsgBox(16, "Timer Error", "Failed to set the ClearMessage timer.")
		Return SetError(3, 0, False)
	EndIf

	; Store the timer ID returned by Windows
	$iClearMessageID = $aTimer[0]

	Return True
EndFunc

Func ClearMessageTimerStop()
	; Nothing is running
	If $iClearMessageID = 0 Then Return True

	Local $aResult

	If @AutoItX64 Then
		$aResult = DllCall("user32.dll", _
			"bool", "KillTimer", _
			"ptr", 0, _
			"ptr", $iClearMessageID _
		)
	Else
		$aResult = DllCall("user32.dll", _
			"bool", "KillTimer", _
			"hwnd", 0, _
			"uint", $iClearMessageID _
		)
	EndIf

	; Keep the ID if Windows failed to stop the timer
	If @error Or Not IsArray($aResult) Or Not $aResult[0] Then _
		Return False

	$iClearMessageID = 0

	Return True
EndFunc

Func ClearMessageTimer($hWnd, $uMsg, $idEvent, $dwTime)
	; Ignore callbacks from an old timer whose KillTimer result was unresolved
	If $iClearMessageID = 0 Or $idEvent <> $iClearMessageID Then Return

	If $hGUI <> 0 And Not $bMessageLock Then
		$bCallbackLock = True

		If IsNumber($iMessageTimer) And _
			$iMessageDuration > 0 And _
			TimerDiff($iMessageTimer) >= $iMessageDuration Then

			ClearMessage()
		EndIf

		$bCallbackLock = False
	EndIf
EndFunc

Func ClearMessage($bForce = False)
	If $bForce Then $bMessagePending = False

	ClearMessageTimerStop()

	; Preserve the existing GUI only when another notification
	; is genuinely waiting to use it
	If $bMessagePending And Not $bForce Then
		$iMessageTimer = Null
		$iMessageDuration = 0
		Return
	EndIf

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
		If $g_hGraphic <> 0 Then
			_GDIPlus_GraphicsDispose($g_hGraphic)
			$g_hGraphic = 0
		EndIf

		$hGUI = 0
		$g_iMessageOpacity = -1
	EndIf
EndFunc

; ========== ========== ========== ========== ==========

Func _StringInPixelsNoGUI($sString, $hFont, $iColWidth = 0)
	; Get the desktop DC
	Local $hDC = _WinAPI_GetDC(0)
	If Not $hDC Then Return SetError(1, 0, 0)

	; Create a graphics object from the DC
	Local $hGraphic = _GDIPlus_GraphicsCreateFromHDC($hDC)
	If @error Or $hGraphic = 0 Then
		_WinAPI_ReleaseDC(0, $hDC)
		Return SetError(2, 0, 0)
	EndIf

	; Set up a measurable character range covering the entire string
	Local $aRanges[2][2] = [[1]]
	$aRanges[1][0] = 0
	$aRanges[1][1] = StringLen($sString)

	; Create a StringFormat object for measurement
	Local $hFormat = _GDIPlus_StringFormatCreate()
	If @error Or $hFormat = 0 Then
		_GDIPlus_GraphicsDispose($hGraphic)
		_WinAPI_ReleaseDC(0, $hDC)
		Return SetError(3, 0, 0)
	EndIf

	_GDIPlus_StringFormatSetMeasurableCharacterRanges($hFormat, $aRanges)
	If @error Then
		_GDIPlus_StringFormatDispose($hFormat)
		_GDIPlus_GraphicsDispose($hGraphic)
		_WinAPI_ReleaseDC(0, $hDC)
		Return SetError(4, 0, 0)
	EndIf

	If Not _GDIPlus_GraphicsSetTextRenderingHint($hGraphic, $GDIP_TEXTRENDERINGHINT_ANTIALIASGRIDFIT) Then
		_GDIPlus_StringFormatDispose($hFormat)
		_GDIPlus_GraphicsDispose($hGraphic)
		_WinAPI_ReleaseDC(0, $hDC)
		Return SetError(5, @error, 0)
	EndIf

	; If no column width is provided, use a large width
	If $iColWidth = 0 Then $iColWidth = 1000
	Local $tLayout = _GDIPlus_RectFCreate(0, 0, $iColWidth, 1000)

	; Measure the character ranges
	Local $aRegions = _GDIPlus_GraphicsMeasureCharacterRanges($hGraphic, $sString, $hFont, $tLayout, $hFormat)
	If @error Or Not IsArray($aRegions) Or UBound($aRegions) < 2 Or $aRegions[0] < 1 Then
		_GDIPlus_StringFormatDispose($hFormat)
		_GDIPlus_GraphicsDispose($hGraphic)
		_WinAPI_ReleaseDC(0, $hDC)
		Return SetError(6, 0, 0)
	EndIf

	Local $aBounds = _GDIPlus_RegionGetBounds($aRegions[1], $hGraphic)
	If @error Or Not IsArray($aBounds) Or UBound($aBounds) < 4 Then
		_GDIPlus_StringFormatDispose($hFormat)
		For $i = 1 To $aRegions[0]
			_GDIPlus_RegionDispose($aRegions[$i])
		Next
		_GDIPlus_GraphicsDispose($hGraphic)
		_WinAPI_ReleaseDC(0, $hDC)
		Return SetError(7, 0, 0)
	EndIf

	; Get the measured width and height
	Local $aWidthHeight[2] = [$aBounds[2], $aBounds[3]]

	; Clean up
	_GDIPlus_StringFormatDispose($hFormat)
	For $i = 1 To $aRegions[0]
		_GDIPlus_RegionDispose($aRegions[$i])
	Next
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
	If $hAboutGUI <> 0 And WinExists($hAboutGUI) Then
		$bAbout = True
		WinSetState($hAboutGUI, "", @SW_RESTORE)
		WinActivate($hAboutGUI)
		Return
	EndIf

	$hAboutGUI = GUICreate("About Browser Cursor Lock", 400, 200, -1, -1, $WS_CAPTION + $WS_POPUP + $WS_SYSMENU)
	$bAbout = True

	; Use the .exe's internal icon
	GUICtrlCreateIcon(@ScriptFullPath, 0, 30, 10, 48, 48)

	Local $sVersion = FileGetVersion(@ScriptFullPath)
	If @error Or StringStripWS($sVersion, 3) = "" Then $sVersion = "1.0.0.0"

	GUICtrlCreateLabel("Browser Cursor Lock", 100, 10, 250, 25)
	GUICtrlSetFont(-1, 12, 700)
	GUICtrlCreateLabel("Version: " & $sVersion, 100, 35, 250, 20)
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

Func _ProcessAboutMessage($iMsgID, $hMsgSource)
	; Ignore messages that do not belong to the About GUI. This lets the
	; normal main loop and the modal Settings loop share one About handler
	; without confusing one GUI's $GUI_EVENT_CLOSE with the other.
	If Not $bAbout Or $hAboutGUI = 0 Or $hMsgSource <> $hAboutGUI Then Return False

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

	Return True
EndFunc

Func LinkGitHubClick()
	DisplayMessage("Going to Github!")
	Local $iPID = ShellExecute("https://github.com/TechTank/Browser-Cursor-Lock")
	If @error Or $iPID = 0 Then DisplayMessage("Unable to open GitHub")
EndFunc

Func LinkPaypalClick()
	DisplayMessage("Going to Paypal!")
	Local $iPID = ShellExecute("https://paypal.me/broganat")
	If @error Or $iPID = 0 Then DisplayMessage("Unable to open PayPal")
EndFunc

Func LinkBraveClick()
	DisplayMessage("Going to brogan.at")
	Local $iPID = ShellExecute("https://brogan.at/brave")
	If @error Or $iPID = 0 Then DisplayMessage("Unable to open brogan.at")
EndFunc

Func _MakeLabelLinkStyle($id)
	GUICtrlSetColor($id, 0x0000FF) ; Blue
	GUICtrlSetFont($id, Default, Default, $GUI_FONTUNDERLINE, "Segoe UI")
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
Global $g_oKeyMap = 0

Global $configFontSize, $configFont, $configOpacity, $configDuration
Global $configSplashMessages, $configBrowserMessages, $configGameMessages
Global $configLockCursorFullscreen, $configLockCursorWindowed, $configLockCursorAllTitles
Global $configAutoLockFullscreenGames, $configAutoLockFullscreenBrowsers

Global $bCapturing = False

; When the configuration window opens, make temporary copies
Global $tmpBrowsers
Global $tmpGames
Global $g_iSelectedBrowserIndex = -1
Global $g_iSelectedGameIndex = -1
Global $hConfigGUI = 0

;--- Configuration Window Code ---
Func _ResetWindowDetectionState()
	If $currentHotkey <> "" Then
		If HotKeySet($currentHotkey) = 0 Then Return False
		$currentHotkey = ""
	EndIf

	$browser = -1
	$game = -1
	$g_hActiveHwnd = 0
	$g_hLastHwnd = 0
	$g_sLastWindowTitle = ""

	$g_bAutoLockSuppressed = False
	$g_hAutoLockSuppressedHwnd = 0
EndFunc

;--- Configuration Window Code ---
Func ShowConfigWindow()
	; Configuration pauses normal lock monitoring, so never enter it while
	; Browser Cursor Lock still owns an active cursor restriction
	If $g_bCursorLocked And Not ReleaseCursorLockIfOwned() Then
		MsgBox(16, "Cursor Lock Error", "Unable to safely release the current cursor lock. Please try opening Settings again.")
		Return
	EndIf

	; Keep the global lock/unlock hotkey inactive while Settings and hotkey
	; capture are running. Detection will rebuild it once Settings closes
	If $currentHotkey <> "" Then
		HotKeySet($currentHotkey)
		$currentHotkey = ""
	EndIf

	ClearMessage(True)
	TraySetClick(0)

	$tmpBrowsers = $g_aBrowsers
	$tmpGames = $g_aGames
	$g_iSelectedBrowserIndex = -1
	$g_iSelectedGameIndex = -1

	; Temporary arrays $tmpBrowsers and $tmpGames now hold copies of the global arrays
	$hConfigGUI = GUICreate("Browser Cursor Lock - Configuration", 445, 540)
	Local Const $ES_NUMBER = 0x2000 ; Restrict input to numbers only

	; === Create Tabs ===
	Local $hTab = GUICtrlCreateTab(10, 10, 427, 485)

	; =========================
	; === General Settings Tab ===
	; =========================
	Local $hTabGeneral = GUICtrlCreateTabItem("General")
	Local $hGeneralGroup = GUICtrlCreateGroup("", 10, 40, 430, 460)

		; ---- Lock Settings ----
		Local $hLockGroup = GUICtrlCreateGroup("Lock Settings", 20, 40, 405, 130)
			Local $hLockFullscreen = GUICtrlCreateCheckbox("Lock Cursor in Fullscreen", 30, 60, 250, 20)
			Local $hLockWindowed = GUICtrlCreateCheckbox("Lock Cursor in Windowed Mode", 30, 80, 250, 20)
			Local $hLockAllTitles = GUICtrlCreateCheckbox("Lock All Browser Windows", 30, 100, 250, 20)
			Local $hAutoLockFullscreenGames = GUICtrlCreateCheckbox("Auto Lock Fullscreen Games", 30, 120, 250, 20)
			Local $hAutoLockFullscreenBrowsers = GUICtrlCreateCheckbox("Auto Lock Fullscreen Browsers", 30, 140, 250, 20)

			GUICtrlSetState($hLockFullscreen, $configLockCursorFullscreen ? $GUI_CHECKED : $GUI_UNCHECKED)
			GUICtrlSetState($hLockWindowed, $configLockCursorWindowed ? $GUI_CHECKED : $GUI_UNCHECKED)
			GUICtrlSetState($hLockAllTitles, $configLockCursorAllTitles ? $GUI_CHECKED : $GUI_UNCHECKED)
			GUICtrlSetState($hAutoLockFullscreenGames, $configAutoLockFullscreenGames ? $GUI_CHECKED : $GUI_UNCHECKED)
			GUICtrlSetState($hAutoLockFullscreenBrowsers, $configAutoLockFullscreenBrowsers ? $GUI_CHECKED : $GUI_UNCHECKED)
		
			; Browser auto-lock already includes games
			; Keep the user's real Games preference separately while
			; the checkbox is visually forced on
			Local $bAutoLockGamesUserState = $configAutoLockFullscreenGames <> 0
			If $configAutoLockFullscreenBrowsers Then
				GUICtrlSetState($hAutoLockFullscreenGames, $GUI_CHECKED)
				GUICtrlSetState($hAutoLockFullscreenGames, $GUI_DISABLE)
			EndIf

			; Auto-lock depends on fullscreen locking
			; Preserve the saved preferences while disabling controls that
			; cannot currently operate
			If Not $configLockCursorFullscreen Then
				GUICtrlSetState($hAutoLockFullscreenGames, $GUI_DISABLE)
				GUICtrlSetState($hAutoLockFullscreenBrowsers, $GUI_DISABLE)
			EndIf
		GUICtrlCreateGroup("", -99, -99, 1, 1) ; Close Lock Settings Group

		; ---- Hotkey Configuration ----
		Local $hHotkeyGroup = GUICtrlCreateGroup("Hotkey Settings", 20, 180, 405, 55)
			GUICtrlCreateLabel("Set Lock/Unlock Hotkey:", 40, 200, 160, 20)
			Local $hHotkeyInput = GUICtrlCreateInput($configHotkey, 170, 200, 130, 20)
			Local $hBtnStart = GUICtrlCreateButton("Start Capture", 310, 200, 100, 20)
			GUICtrlCreateGroup("", -99, -99, 1, 1) ; Close Hotkey Settings Group

			; ---- Notifications (Message Settings) ----
			Local $hMessageGroup = GUICtrlCreateGroup("Message Settings", 20, 245, 405, 90)
			Local $hSplashMessages = GUICtrlCreateCheckbox("Enable Splash Messages", 30, 265, 180, 20)
			Local $hBrowserMessages = GUICtrlCreateCheckbox("Enable Browser Detection Messages", 30, 285, 280, 20)
			Local $hGameMessages = GUICtrlCreateCheckbox("Enable Game Detection Messages", 30, 305, 280, 20)

			GUICtrlSetState($hSplashMessages, $configSplashMessages ? $GUI_CHECKED : $GUI_UNCHECKED)
			GUICtrlSetState($hBrowserMessages, $configBrowserMessages ? $GUI_CHECKED : $GUI_UNCHECKED)
			GUICtrlSetState($hGameMessages, $configGameMessages ? $GUI_CHECKED : $GUI_UNCHECKED)
		GUICtrlCreateGroup("", -99, -99, 1, 1) ; Close Message Settings Group

		; ---- Display Settings ----
		Local $hDisplayGroup = GUICtrlCreateGroup("Display Settings", 20, 340, 405, 145)
			GUICtrlCreateLabel("Message Opacity:", 40, 360, 120, 20)
			Local $hOpacitySlider = GUICtrlCreateSlider(160, 360, 180, 20)
			GUICtrlSetLimit($hOpacitySlider, 255, 1)
			GUICtrlSetData($hOpacitySlider, $configOpacity)
			Local $hOpacityLabel = GUICtrlCreateLabel(_OpacityToPercentage($configOpacity), 350, 360, 50, 20)

			GUICtrlCreateLabel("Duration (ms):", 40, 390, 120, 20)
			Local $hDuration = GUICtrlCreateInput($configDuration, 160, 390, 80, 20, $ES_NUMBER)

			GUICtrlCreateLabel("Font Size:", 40, 420, 120, 20)
			Local $hFontSize = GUICtrlCreateInput($configFontSize, 160, 420, 50, 20, $ES_NUMBER)

			GUICtrlCreateLabel("Font:", 40, 450, 120, 20)
			Local $fontList = _GetFontList()
			Local $hFontDropdown = GUICtrlCreateCombo("", 160, 450, 180, 20)
			For $i = 0 To UBound($fontList) - 1
				GUICtrlSetData($hFontDropdown, $fontList[$i])
			Next
			GUICtrlSetData($hFontDropdown, $configFont)
		GUICtrlCreateGroup("", -99, -99, 1, 1) ; End Display Group

	GUICtrlCreateGroup("", -99, -99, 1, 1) ; Close General Config Group

	; =========================
	; === Browser Configuration Tab ===
	; =========================
	Local $hTabBrowser = GUICtrlCreateTabItem("Browser Configuration")
	Local $hBrowserGroup = GUICtrlCreateGroup("", 10, 40, 430, 460)
		GUICtrlCreateLabel("Browsers:", 30, 60, 100, 20)
		Local $hBrowserList = GUICtrlCreateList("", 30, 80, 385, 180, BitOR($WS_BORDER, $WS_VSCROLL, $LBS_DISABLENOSCROLL))

		; Populate with one real listbox item per configured browser so display
		; names may safely contain characters such as |
		_RefreshConfigList($hBrowserList, $tmpBrowsers)

		Local $hAddBrowser = GUICtrlCreateButton("Add", 365, 45, 50, 30)
		; Editable fields for selected browser
		GUICtrlCreateLabel("ID:", 30, 280, 100, 20)
		Local $hBrowserID = GUICtrlCreateInput("", 140, 280, 200, 20)
		GUICtrlCreateLabel("Display Name:", 30, 310, 100, 20)
		Local $hBrowserDisplay = GUICtrlCreateInput("", 140, 310, 200, 20)
		GUICtrlCreateLabel("Title Regex:", 30, 340, 100, 20)
		Local $hBrowserTitle = GUICtrlCreateInput("", 140, 340, 200, 20)

		GUICtrlCreateLabel("Windowed Offsets:", 30, 370)
		GUICtrlCreateLabel("T", 180, 370, 10, 20)
		Local $hWindowOffsetT = GUICtrlCreateInput("", 195, 370, 35, 20)
		GUICtrlCreateLabel("R", 240, 370, 10, 20)
		Local $hWindowOffsetR = GUICtrlCreateInput("", 255, 370, 35, 20)
		GUICtrlCreateLabel("B", 300, 370, 10, 20)
		Local $hWindowOffsetB = GUICtrlCreateInput("", 315, 370, 35, 20)
		GUICtrlCreateLabel("L", 360, 370, 10, 20)
		Local $hWindowOffsetL = GUICtrlCreateInput("", 375, 370, 35, 20)

		GUICtrlCreateLabel("Fullscreen Offsets:", 30, 400)
		GUICtrlCreateLabel("T", 180, 400, 10, 20)
		Local $hFullscreenOffsetT = GUICtrlCreateInput("", 195, 400, 35, 20)
		GUICtrlCreateLabel("R", 240, 400, 10, 20)
		Local $hFullscreenOffsetR = GUICtrlCreateInput("", 255, 400, 35, 20)
		GUICtrlCreateLabel("B", 300, 400, 10, 20)
		Local $hFullscreenOffsetB = GUICtrlCreateInput("", 315, 400, 35, 20)
		GUICtrlCreateLabel("L", 360, 400, 10, 20)
		Local $hFullscreenOffsetL = GUICtrlCreateInput("", 375, 400, 35, 20)

		Local $hRemoveBrowser = GUICtrlCreateButton("Remove", 315, 450, 100, 30)
		GUICtrlSetState($hRemoveBrowser, $GUI_HIDE)
	GUICtrlCreateGroup("", -99, -99, 1, 1) ; End Browser Group

	Local $aBrowserControls = [$hBrowserID, $hBrowserDisplay, $hBrowserTitle, _
											 $hWindowOffsetT, $hWindowOffsetR, $hWindowOffsetB, $hWindowOffsetL, _
											 $hFullscreenOffsetT, $hFullscreenOffsetR, $hFullscreenOffsetB, $hFullscreenOffsetL]

	; =========================
	; === Game Configuration Tab ===
	; =========================
	Local $hTabGame = GUICtrlCreateTabItem("Game Configuration")
	Local $hGameGroup = GUICtrlCreateGroup("", 10, 40, 430, 460)
		GUICtrlCreateLabel("Games:", 30, 60, 100, 20)
		Local $hGameList = GUICtrlCreateList("", 30, 80, 385, 180, BitOR($WS_BORDER, $WS_VSCROLL, $LBS_DISABLENOSCROLL))

		; Use the same item-by-item population as the browser list
		_RefreshConfigList($hGameList, $tmpGames)

		Local $hAddGame = GUICtrlCreateButton("Add", 365, 45, 50, 30)
		; Editable fields for selected game
		GUICtrlCreateLabel("ID:", 30, 280, 100, 20)
		Local $hGameID = GUICtrlCreateInput("", 140, 280, 200, 20)
		GUICtrlCreateLabel("Display Name:", 30, 310, 100, 20)
		Local $hGameDisplay = GUICtrlCreateInput("", 140, 310, 200, 20)
		GUICtrlCreateLabel("Title Regex:", 30, 340, 100, 20)
		Local $hGameTitle = GUICtrlCreateInput("", 140, 340, 200, 20)

		GUICtrlCreateLabel("Windowed Offsets:", 30, 370)
		GUICtrlCreateLabel("T", 180, 370, 10, 20)
		Local $hGameWindowOffsetT = GUICtrlCreateInput("", 195, 370, 35, 20)
		GUICtrlCreateLabel("R", 240, 370, 10, 20)
		Local $hGameWindowOffsetR = GUICtrlCreateInput("", 255, 370, 35, 20)
		GUICtrlCreateLabel("B", 300, 370, 10, 20)
		Local $hGameWindowOffsetB = GUICtrlCreateInput("", 315, 370, 35, 20)
		GUICtrlCreateLabel("L", 360, 370, 10, 20)
		Local $hGameWindowOffsetL = GUICtrlCreateInput("", 375, 370, 35, 20)

		GUICtrlCreateLabel("Fullscreen Offsets:", 30, 400)
		GUICtrlCreateLabel("T", 180, 400, 10, 20)
		Local $hGameFullscreenOffsetT = GUICtrlCreateInput("", 195, 400, 35, 20)
		GUICtrlCreateLabel("R", 240, 400, 10, 20)
		Local $hGameFullscreenOffsetR = GUICtrlCreateInput("", 255, 400, 35, 20)
		GUICtrlCreateLabel("B", 300, 400, 10, 20)
		Local $hGameFullscreenOffsetB = GUICtrlCreateInput("", 315, 400, 35, 20)
		GUICtrlCreateLabel("L", 360, 400, 10, 20)
		Local $hGameFullscreenOffsetL = GUICtrlCreateInput("", 375, 400, 35, 20)

		Local $hRemoveGame = GUICtrlCreateButton("Remove", 315, 450, 100, 30)
		GUICtrlSetState($hRemoveGame, $GUI_HIDE)
	GUICtrlCreateGroup("", -99, -99, 1, 1) ; End Game Group

	Local $aGameControls = [$hGameID, $hGameDisplay, $hGameTitle, _
										$hGameWindowOffsetT, $hGameWindowOffsetR, $hGameWindowOffsetB, $hGameWindowOffsetL, _
										$hGameFullscreenOffsetT, $hGameFullscreenOffsetR, $hGameFullscreenOffsetB, $hGameFullscreenOffsetL]

	GUICtrlCreateTabItem("") ; Close Tabs

	; =========================
	; === Bottom Buttons ===
	; =========================
	Local $hSave = GUICtrlCreateButton("Save", 260, 500, 80, 30)
	Local $hCancel = GUICtrlCreateButton("Cancel", 350, 500, 80, 30)

	GUISetState(@SW_SHOW, $hConfigGUI)

	; Ensure Only the Selected Tab's Group is Visible
	Local $aGroups[3] = [$hGeneralGroup, $hBrowserGroup, $hGameGroup]
	_UpdateTabVisibility($hTab, $aGroups)

	; Initially disable all browser/game controls
	_EnableControls($aBrowserControls, False)
	_EnableControls($aGameControls, False)

	; While hotkey capture owns its modal loop, freeze every other interactive
	; Settings control so its state cannot change without its normal event handler
	; Start Capture/Cancel Capture and the Settings Cancel button stay active
	Local $aHotkeyCaptureLockedControls = [ _
		$hTab, $hSave, _
		$hLockFullscreen, $hLockWindowed, $hLockAllTitles, _
		$hAutoLockFullscreenGames, $hAutoLockFullscreenBrowsers, _
		$hSplashMessages, $hBrowserMessages, $hGameMessages, _
		$hOpacitySlider, $hDuration, $hFontSize, $hFontDropdown, _
		$hBrowserList, $hAddBrowser, $hBrowserID, $hBrowserDisplay, $hBrowserTitle, _
		$hWindowOffsetT, $hWindowOffsetR, $hWindowOffsetB, $hWindowOffsetL, _
		$hFullscreenOffsetT, $hFullscreenOffsetR, $hFullscreenOffsetB, $hFullscreenOffsetL, $hRemoveBrowser, _
		$hGameList, $hAddGame, $hGameID, $hGameDisplay, $hGameTitle, _
		$hGameWindowOffsetT, $hGameWindowOffsetR, $hGameWindowOffsetB, $hGameWindowOffsetL, _
		$hGameFullscreenOffsetT, $hGameFullscreenOffsetR, $hGameFullscreenOffsetB, $hGameFullscreenOffsetL, $hRemoveGame _
	]

	; =========================
	; === Event Loop ===
	; =========================
	While True
		; Advanced GUI mode identifies which window generated the event
		; About may already be open when Settings starts, so route its events separately
		Local $aConfigMsg = GUIGetMsg(1)
		Local $iConfigMsgID = $aConfigMsg[0]
		Local $hConfigMsgSource = $aConfigMsg[1]

		If $bAbout And _ProcessAboutMessage($iConfigMsgID, $hConfigMsgSource) Then
			Sleep(10)
			ContinueLoop
		EndIf
		
		; Ignore messages from any GUI other than this Settings window
		; In particular, an About close event must never cancel Settings
		If $hConfigMsgSource <> $hConfigGUI Then
			Sleep(10)
			ContinueLoop
		EndIf

		Switch $iConfigMsgID
			Case $GUI_EVENT_CLOSE, $hCancel
				_ResetWindowDetectionState()
				GUIDelete($hConfigGUI)
				TraySetClick(9)
				ExitLoop

			Case $hSave
				; Capture any changes made in browser and game list boxes
				If $g_iSelectedBrowserIndex <> -1 Then
					_CaptureBrowserFields($hBrowserList, $hBrowserID, $hBrowserDisplay, $hBrowserTitle, _
						$hWindowOffsetT, $hWindowOffsetR, $hWindowOffsetB, $hWindowOffsetL, _
						$hFullscreenOffsetT, $hFullscreenOffsetR, $hFullscreenOffsetB, $hFullscreenOffsetL)

					If @error Then ContinueLoop
				EndIf

				If $g_iSelectedGameIndex <> -1 Then
					_CaptureGameFields($hGameList, $hGameID, $hGameDisplay, $hGameTitle, _
						$hGameWindowOffsetT, $hGameWindowOffsetR, $hGameWindowOffsetB, $hGameWindowOffsetL, _
						$hGameFullscreenOffsetT, $hGameFullscreenOffsetR, $hGameFullscreenOffsetB, $hGameFullscreenOffsetL)

					If @error Then ContinueLoop
				EndIf

				; Preserve the real Games preference when Browser auto-lock is forcing
				; the Games checkbox to appear checked/disabled
				If GUICtrlRead($hAutoLockFullscreenBrowsers) <> $GUI_CHECKED Then _
					$bAutoLockGamesUserState = GUICtrlRead($hAutoLockFullscreenGames) = $GUI_CHECKED

				; Persist the complete configuration before committing temporary data
				; to the running program
				If Not _SaveConfig($hHotkeyInput, $hLockFullscreen, $hLockWindowed, $hLockAllTitles, _
					$hAutoLockFullscreenGames, $hAutoLockFullscreenBrowsers, $bAutoLockGamesUserState, _
					$hSplashMessages, $hBrowserMessages, $hGameMessages, $hFontDropdown, $hFontSize, _
					$hOpacitySlider, $hDuration) Then ContinueLoop

				; Only expose the edited arrays after every INI write succeeded
				$g_aBrowsers = $tmpBrowsers
				$g_aGames = $tmpGames

				MsgBox(64, "Settings Saved", "Configuration has been updated.")

				; Re-detect the active window using the newly saved configuration
				; to rebuild the hotkey state once
				_ResetWindowDetectionState()

				; ==========

				GUIDelete($hConfigGUI)
				TraySetClick(9)
				ExitLoop

			Case $hBtnStart
				; Capture is modal, but the button becomes Cancel Capture and the
				; Settings close/cancel actions remain responsive inside the capture loop
				_CaptureHotkey($hHotkeyInput, $hBtnStart, $hCancel, $aHotkeyCaptureLockedControls)
				Local $iCaptureError = @error

				If $iCaptureError = 1 Then
					_ResetWindowDetectionState()
					GUIDelete($hConfigGUI)
					TraySetClick(9)
					ExitLoop
				EndIf

			Case $hTab
				Local $aGroups[3] = [$hGeneralGroup, $hBrowserGroup, $hGameGroup]
				_UpdateTabVisibility($hTab, $aGroups)

			Case $hLockFullscreen
				If GUICtrlRead($hLockFullscreen) = $GUI_CHECKED Then
					GUICtrlSetState($hAutoLockFullscreenBrowsers, $GUI_ENABLE)

					If GUICtrlRead($hAutoLockFullscreenBrowsers) = $GUI_CHECKED Then
						GUICtrlSetState($hAutoLockFullscreenGames, $GUI_CHECKED)
						GUICtrlSetState($hAutoLockFullscreenGames, $GUI_DISABLE)
					Else
						GUICtrlSetState($hAutoLockFullscreenGames, $GUI_ENABLE)
						GUICtrlSetState($hAutoLockFullscreenGames, _
							$bAutoLockGamesUserState ? $GUI_CHECKED : $GUI_UNCHECKED)
					EndIf
				Else
					If GUICtrlRead($hAutoLockFullscreenBrowsers) <> $GUI_CHECKED Then _
						$bAutoLockGamesUserState = GUICtrlRead($hAutoLockFullscreenGames) = $GUI_CHECKED

					GUICtrlSetState($hAutoLockFullscreenGames, $GUI_DISABLE)
					GUICtrlSetState($hAutoLockFullscreenBrowsers, $GUI_DISABLE)
				EndIf

			Case $hAutoLockFullscreenGames
				; Only update the user's real preference while the control is editable
				If GUICtrlRead($hAutoLockFullscreenBrowsers) <> $GUI_CHECKED Then _
					$bAutoLockGamesUserState = GUICtrlRead($hAutoLockFullscreenGames) = $GUI_CHECKED

			Case $hAutoLockFullscreenBrowsers
				If GUICtrlRead($hAutoLockFullscreenBrowsers) = $GUI_CHECKED Then
					; Remember the user's current Games choice, then show that Browser
					; auto-lock inherently includes games
					$bAutoLockGamesUserState = GUICtrlRead($hAutoLockFullscreenGames) = $GUI_CHECKED
					GUICtrlSetState($hAutoLockFullscreenGames, $GUI_CHECKED)
					GUICtrlSetState($hAutoLockFullscreenGames, $GUI_DISABLE)
				Else
					GUICtrlSetState($hAutoLockFullscreenGames, $GUI_ENABLE)
					GUICtrlSetState($hAutoLockFullscreenGames, _
						$bAutoLockGamesUserState ? $GUI_CHECKED : $GUI_UNCHECKED)
				EndIf

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

						If @error Then
							_GUICtrlListBox_SetCurSel($hBrowserList, $g_iSelectedBrowserIndex)
							ContinueLoop
						EndIf
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

						If @error Then
							_GUICtrlListBox_SetCurSel($hGameList, $g_iSelectedGameIndex)
							ContinueLoop
						EndIf
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

					If @error Then ContinueLoop
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
					; An empty list is valid and is persisted explicitly as ids=|
					; so it remains distinct from a missing first-run configuration
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

					If @error Then ContinueLoop
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
					; An empty list is valid and is persisted explicitly as ids=|
					; so it remains distinct from a missing first-run configuration.
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
		Sleep(10)
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

Func _IsInt32Value($vValue)
	If Not IsNumber($vValue) Then Return False
	Return $vValue >= -2147483648 And $vValue <= 2147483647
EndFunc

Func _IsSignedInt32String($sValue)
	$sValue = StringStripWS($sValue, 3)
	If Not StringRegExp($sValue, "^-?\d+$") Then Return False

	Local $nValue = Number($sValue)
	Return _IsInt32Value($nValue)
EndFunc

Func _NormalizeOffsetString($sOffsets, $sDefault = "0,0,0,0")
	$sOffsets = StringStripWS($sOffsets, 3)
	$sOffsets = StringRegExpReplace($sOffsets, "[, ]+$", "")
	Local $aOffsets = StringSplit($sOffsets, ",", 2)
	If UBound($aOffsets) <> 4 Then Return $sDefault

	Local $sNormalized = ""
	For $i = 0 To 3
		Local $sValue = StringStripWS($aOffsets[$i], 3)
		If Not _IsSignedInt32String($sValue) Then Return $sDefault
		If $i > 0 Then $sNormalized &= ","
		$sNormalized &= $sValue
	Next

	Return $sNormalized
EndFunc

Func _ReadOffsetSet($hTop, $hRight, $hBottom, $hLeft, $sDescription)
	Local $aControls[4] = [$hTop, $hRight, $hBottom, $hLeft]
	Local $aDirections[4] = ["Top", "Right", "Bottom", "Left"]
	Local $sOffsets = ""

	For $i = 0 To 3
		Local $sValue = StringStripWS(GUICtrlRead($aControls[$i]), 3)

		If Not _IsSignedInt32String($sValue) Then
			MsgBox(16, "Invalid Offset", $sDescription & " " & $aDirections[$i] & " offset must be a whole number between -2147483648 and 2147483647.")
			Return SetError(1, 0, "")
		EndIf

		If $i > 0 Then $sOffsets &= ","
		$sOffsets &= $sValue
	Next

	Return $sOffsets
EndFunc

Func _RefreshConfigList($hList, ByRef $aData)
	; Preserve the selection the user currently sees
	; During a row change this may already be the new row while
	; we are still saving the previous one
	Local $iSelected = _GUICtrlListBox_GetCurSel($hList)

	; Add each display name as an actual listbox item instead of using
	; GUICtrlSetData's | delimiter, so | is valid inside display names
	_GUICtrlListBox_ResetContent($hList)

	For $i = 0 To UBound($aData, 1) - 1
		_GUICtrlListBox_AddString($hList, $aData[$i][1])
	Next

	If $iSelected >= 0 And $iSelected < UBound($aData, 1) Then _
		_GUICtrlListBox_SetCurSel($hList, $iSelected)
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
	If $id = "" Then
		MsgBox(16, "Invalid ID", "Browser ID cannot be blank.")
		Return SetError(3, 0, 0)
	EndIf

	If $display = "" Then
		MsgBox(16, "Invalid Display Name", "Browser display name cannot be blank.")
		Return SetError(4, 0, 0)
	EndIf

	If Not StringRegExp($id, "^[A-Za-z0-9_-]+$") Then
		MsgBox(16, "Invalid ID", "Browser ID may contain only letters, numbers, underscores, and hyphens.")
		Return SetError(5, 0, 0)
	EndIf

	If Not _IsValidRegex($title) Then
		MsgBox(16, "Invalid Regex", "The browser title regex is invalid.")
		Return SetError(1, 0, 0)
	EndIf

	If _IDExists($tmpBrowsers, $id, 0, $index) Then
		MsgBox(16, "Duplicate ID", "Another browser already uses the ID '" & $id & "'.")
		Return SetError(2, 0, 0)
	EndIf

	; Validate and normalize signed integer offsets
	Local $winOffsets = _ReadOffsetSet($hWindowOffsetT, $hWindowOffsetR, $hWindowOffsetB, $hWindowOffsetL, "Browser windowed")
	If @error Then Return SetError(6, 0, 0)

	Local $fullOffsets = _ReadOffsetSet($hFullscreenOffsetT, $hFullscreenOffsetR, $hFullscreenOffsetB, $hFullscreenOffsetL, "Browser fullscreen")
	If @error Then Return SetError(7, 0, 0)

	; Save values
	$tmpBrowsers[$index][0] = $id
	$tmpBrowsers[$index][1] = $display
	$tmpBrowsers[$index][2] = $title
	$tmpBrowsers[$index][3] = $winOffsets
	$tmpBrowsers[$index][4] = $fullOffsets

	; Keep the visible list synchronized with edited display names
	_RefreshConfigList($hBrowserList, $tmpBrowsers)
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
	If $id = "" Then
		MsgBox(16, "Invalid ID", "Game ID cannot be blank.")
		Return SetError(3, 0, 0)
	EndIf

	If $display = "" Then
		MsgBox(16, "Invalid Display Name", "Game display name cannot be blank.")
		Return SetError(4, 0, 0)
	EndIf

	If Not StringRegExp($id, "^[A-Za-z0-9_-]+$") Then
		MsgBox(16, "Invalid ID", "Game ID may contain only letters, numbers, underscores, and hyphens.")
		Return SetError(5, 0, 0)
	EndIf

	If Not _IsValidRegex($title) Then
		MsgBox(16, "Invalid Regex", "The game title regex is invalid.")
		Return SetError(1, 0, 0)
	EndIf

	If _IDExists($tmpGames, $id, 0, $index) Then
		MsgBox(16, "Duplicate ID", "Another game already uses the ID '" & $id & "'.")
		Return SetError(2, 0, 0)
	EndIf

	; Validate and normalize signed integer offsets
	Local $winOffsets = _ReadOffsetSet($hGameWindowOffsetT, $hGameWindowOffsetR, $hGameWindowOffsetB, $hGameWindowOffsetL, "Game windowed")
	If @error Then Return SetError(6, 0, 0)

	Local $fullOffsets = _ReadOffsetSet($hGameFullscreenOffsetT, $hGameFullscreenOffsetR, $hGameFullscreenOffsetB, $hGameFullscreenOffsetL, "Game fullscreen")
	If @error Then Return SetError(7, 0, 0)

	; Save values
	$tmpGames[$index][0] = $id
	$tmpGames[$index][1] = $display
	$tmpGames[$index][2] = $title
	$tmpGames[$index][3] = $winOffsets
	$tmpGames[$index][4] = $fullOffsets

	; Keep the visible list synchronized with edited display names
	_RefreshConfigList($hGameList, $tmpGames)
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
	$hAutoLockFullscreenGames, $hAutoLockFullscreenBrowsers, $bAutoLockGamesUserState, _
	$hSplashMessages, $hBrowserMessages, $hGameMessages, $hFontDropdown, $hFontSize, _
	$hOpacitySlider, $hDuration)

	Local $newHotkey = GUICtrlRead($hHotkeyInput)
	Local $lockFullscreen = GUICtrlRead($hLockFullscreen) = $GUI_CHECKED ? "1" : "0"
	Local $lockWindowed = GUICtrlRead($hLockWindowed) = $GUI_CHECKED ? "1" : "0"
	Local $lockAllTitles = GUICtrlRead($hLockAllTitles) = $GUI_CHECKED ? "1" : "0"

	; Use the remembered Games preference rather than the forced visual state.
	Local $autoLockFullscreenGames = $bAutoLockGamesUserState ? "1" : "0"
	Local $autoLockFullscreenBrowsers = GUICtrlRead($hAutoLockFullscreenBrowsers) = $GUI_CHECKED ? "1" : "0"

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

	; Validate the selected/typed font family and the actual requested size
	; before either can become the live setting
	Local $hTestFontFamily = _GDIPlus_FontFamilyCreate($fontName)
	If @error Or $hTestFontFamily = 0 Then
		MsgBox(16, "Font Error", "The selected font '" & $fontName & "' could not be loaded.")
		Return False
	EndIf

	Local $hTestFont = _GDIPlus_FontCreate($hTestFontFamily, $fontSize, 0)
	If @error Or $hTestFont = 0 Then
		_GDIPlus_FontFamilyDispose($hTestFontFamily)
		MsgBox(16, "Font Error", "The selected font size could not be created.")
		Return False
	EndIf

	_GDIPlus_FontDispose($hTestFont)
	_GDIPlus_FontFamilyDispose($hTestFontFamily)

	; Validate a changed hotkey before committing it to disk
	; Settings keeps the runtime hotkey unregistered, so this
	; registration is only a temporary test
	If StringStripWS($newHotkey, 3) = "" Then $newHotkey = $configHotkey
	If $newHotkey <> $configHotkey Then
		Local $sRegisteredHotkey = $currentHotkey
		If $sRegisteredHotkey <> "" Then HotKeySet($sRegisteredHotkey)

		Local $result = HotKeySet($newHotkey, "ToggleCursorLock")
		If $result = 0 Then
			MsgBox(16, "HotKey Error", "New hotkey '" & $newHotkey & "' could not be set. The previous hotkey will be kept.")
			$newHotkey = $configHotkey
		Else
			; Validation succeeded; release the temporary test registration
			HotKeySet($newHotkey)
		EndIf
	EndIf

	; Keep an exact in-memory binary snapshot so a failed group of INI writes
	; cannot leave a partially saved configuration behind or create a backup file.
	Local $bHadConfig = FileExists($configPath)
	Local $vConfigBackup = Binary("")

	If $bHadConfig Then
		Local $hBackupRead = FileOpen($configPath, 16) ; Binary read
		If $hBackupRead = -1 Then
			MsgBox(16, "Settings Save Error", "Could not read the existing configuration. No settings were changed.")
			Return False
		EndIf

		$vConfigBackup = FileRead($hBackupRead)
		Local $iBackupReadError = @error
		FileClose($hBackupRead)

		; FileRead may report -1 when the requested whole-file read reaches EOF;
		; that still leaves the complete binary snapshot in $vConfigBackup.
		If $iBackupReadError <> 0 And $iBackupReadError <> -1 Then
			MsgBox(16, "Settings Save Error", "Could not read the existing configuration. No settings were changed.")
			Return False
		EndIf
	EndIf

	Local $bWriteOK = True

	; Write general settings to the INI file
	_WriteConfigValue($bWriteOK, "general", "hotkey", $newHotkey)
	_WriteConfigValue($bWriteOK, "cursor", "lock_cursor_fullscreen", $lockFullscreen)
	_WriteConfigValue($bWriteOK, "cursor", "lock_cursor_windowed", $lockWindowed)
	_WriteConfigValue($bWriteOK, "cursor", "lock_all_titles", $lockAllTitles)
	_WriteConfigValue($bWriteOK, "cursor", "auto_lock_fullscreen_games", $autoLockFullscreenGames)
	_WriteConfigValue($bWriteOK, "cursor", "auto_lock_fullscreen_browsers", $autoLockFullscreenBrowsers)
	_WriteConfigValue($bWriteOK, "notifications", "splash_messages", $showSplash)
	_WriteConfigValue($bWriteOK, "notifications", "browser_messages", $showBrowser)
	_WriteConfigValue($bWriteOK, "notifications", "game_messages", $showGame)
	_WriteConfigValue($bWriteOK, "message", "fontfamily", $fontName)
	_WriteConfigValue($bWriteOK, "message", "fontsize", $fontSize)
	_WriteConfigValue($bWriteOK, "message", "opacity", $opacity)
	_WriteConfigValue($bWriteOK, "message", "duration", $duration)

	; Save browser list from the temporary editor data
	Local $sBrowserIDs = ""
	For $i = 0 To UBound($tmpBrowsers, 1) - 1
		If StringStripWS($tmpBrowsers[$i][0], 3) <> "" Then
			$sBrowserIDs &= $tmpBrowsers[$i][0] & ","
		EndIf
	Next

	If $sBrowserIDs <> "" Then
		$sBrowserIDs = StringTrimRight($sBrowserIDs, 1)
	Else
		$sBrowserIDs = "|" ; Reserved sentinel: explicitly configured empty list
	EndIf

	_WriteConfigValue($bWriteOK, "browsers", "ids", $sBrowserIDs)

	For $i = 0 To UBound($tmpBrowsers, 1) - 1
		If StringStripWS($tmpBrowsers[$i][0], 3) <> "" Then
			_WriteConfigValue($bWriteOK, $tmpBrowsers[$i][0] & "_browser", "name", $tmpBrowsers[$i][1])
			_WriteConfigValue($bWriteOK, $tmpBrowsers[$i][0] & "_browser", "title", $tmpBrowsers[$i][2])
			_WriteConfigValue($bWriteOK, $tmpBrowsers[$i][0] & "_browser", "windowed_offsets", $tmpBrowsers[$i][3])
			_WriteConfigValue($bWriteOK, $tmpBrowsers[$i][0] & "_browser", "fullscreen_offsets", $tmpBrowsers[$i][4])
		EndIf
	Next

	; Save game list from the temporary editor data
	Local $sGameIDs = ""
	For $i = 0 To UBound($tmpGames, 1) - 1
		If StringStripWS($tmpGames[$i][0], 3) <> "" Then
			$sGameIDs &= $tmpGames[$i][0] & ","
		EndIf
	Next

	If $sGameIDs <> "" Then
		$sGameIDs = StringTrimRight($sGameIDs, 1)
	Else
		$sGameIDs = "|" ; Reserved sentinel: explicitly configured empty list
	EndIf

	_WriteConfigValue($bWriteOK, "games", "ids", $sGameIDs)

	For $i = 0 To UBound($tmpGames, 1) - 1
		If StringStripWS($tmpGames[$i][0], 3) <> "" Then
			_WriteConfigValue($bWriteOK, $tmpGames[$i][0] & "_game", "name", $tmpGames[$i][1])
			_WriteConfigValue($bWriteOK, $tmpGames[$i][0] & "_game", "title", $tmpGames[$i][2])
			_WriteConfigValue($bWriteOK, $tmpGames[$i][0] & "_game", "windowed_offsets", $tmpGames[$i][3])
			_WriteConfigValue($bWriteOK, $tmpGames[$i][0] & "_game", "fullscreen_offsets", $tmpGames[$i][4])
		EndIf
	Next

	; Remove browser/game sections that are no longer referenced by the current ID lists
	; Any cleanup failure participates in the same exact in-memory rollback as the writes above
	_CleanupObsoleteConfigSections($bWriteOK)

	If Not $bWriteOK Then
		Local $bRollbackOK = True

		If $bHadConfig Then
			Local $hRestore = FileOpen($configPath, 18) ; Overwrite + binary
			If $hRestore = -1 Then
				$bRollbackOK = False
			Else
				If BinaryLen($vConfigBackup) > 0 And FileWrite($hRestore, $vConfigBackup) = 0 Then _
					$bRollbackOK = False
				FileClose($hRestore)
			EndIf
		ElseIf FileExists($configPath) Then
			$bRollbackOK = FileDelete($configPath) <> 0
		EndIf

		If $bRollbackOK Then
			MsgBox(16, "Settings Save Error", "The configuration could not be written. The previous settings were restored.")
		Else
			MsgBox(16, "Settings Save Error", "The configuration could not be written, and the previous configuration could not be fully restored.")
		EndIf

		Return False
	EndIf

	; Update the global configuration variables only after persistence succeeds
	$configHotkey = $newHotkey
	$configLockCursorFullscreen = Number($lockFullscreen)
	$configLockCursorWindowed = Number($lockWindowed)
	$configLockCursorAllTitles = Number($lockAllTitles)
	$configAutoLockFullscreenGames = Number($autoLockFullscreenGames)
	$configAutoLockFullscreenBrowsers = Number($autoLockFullscreenBrowsers)
	$configSplashMessages = Number($showSplash)
	$configBrowserMessages = Number($showBrowser)
	$configGameMessages = Number($showGame)
	$configFont = $fontName
	$configFontSize = $fontSize
	$configOpacity = $opacity
	$configDuration = $duration

	Return True
EndFunc

Func _WriteConfigValue(ByRef $bWriteOK, $sSection, $sKey, $vValue)
	If IniWrite($configPath, $sSection, $sKey, $vValue) = 0 Then $bWriteOK = False
EndFunc

Func _CleanupObsoleteConfigSections(ByRef $bWriteOK)
	If Not $bWriteOK Or Not FileExists($configPath) Then Return

	Local $aSections = IniReadSectionNames($configPath)
	If @error Or Not IsArray($aSections) Then
		$bWriteOK = False
		Return
	EndIf

	For $i = 1 To $aSections[0]
		Local $sSection = $aSections[$i]
		Local $sSectionLower = StringLower($sSection)

		If StringRight($sSectionLower, 8) = "_browser" Then
			Local $sBrowserID = StringTrimRight($sSection, 8)
			If Not _IDExists($tmpBrowsers, $sBrowserID, 0) Then
				If IniDelete($configPath, $sSection) = 0 Then $bWriteOK = False
			EndIf
		ElseIf StringRight($sSectionLower, 5) = "_game" Then
			Local $sGameID = StringTrimRight($sSection, 5)
			If Not _IDExists($tmpGames, $sGameID, 0) Then
				If IniDelete($configPath, $sSection) = 0 Then $bWriteOK = False
			EndIf
		EndIf
	Next
EndFunc

Func _IsValidRegex($sRegex)
	$sRegex = StringStripWS($sRegex, 3)
	If $sRegex = "" Then Return False

	; Runtime detection always prepends (?i), so validate that exact expression
	StringRegExp("test", "(?i)" & $sRegex)
	If @error Then Return False

	Return True
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

Func _IDExists(ByRef $a2D, $sID, $iCol = 0, $iIgnoreRow = -1)
	For $r = 0 To UBound($a2D, 1) - 1
		If $r = $iIgnoreRow Then ContinueLoop

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
	If @error Or Not IsArray($aData) Or UBound($aData) = 0 Then
		Local $aFonts[3] = ["Arial", "Times New Roman", "Courier New"]
		Return $aFonts
	EndIf

	Local $iRows = UBound($aData)
	Local $aResult[$iRows]
	For $i = 0 To $iRows - 1
		$aResult[$i] = $aData[$i][0] ; assuming the first column holds the font names
	Next

	_ArraySort($aResult)
	Return $aResult
EndFunc

; ========== ========== ========== ========== ==========

Func _ReadConfigBool($sSection, $sKey, $iDefault)
	Local $sValue = StringStripWS(IniRead($configPath, $sSection, $sKey, String(Number($iDefault <> 0))), 3)
	If $sValue = "0" Then Return 0
	If $sValue = "1" Then Return 1
	Return Number($iDefault <> 0)
EndFunc

Func _RegexEscapeLiteral($sText)
	Local $sEscaped = ""
	For $i = 1 To StringLen($sText)
		Local $sChar = StringMid($sText, $i, 1)
		If StringInStr("\\.^$|()[]{}*+?", $sChar, 1) Then $sEscaped &= "\"
		$sEscaped &= $sChar
	Next
	Return $sEscaped
EndFunc

; Normalize an INI ID list before allocating the runtime Browser/Game arrays
; Blank, malformed, and duplicate IDs are ignored so they cannot create empty
; rows whose blank title regex could accidentally match a window
Func _CompactConfigIDs(ByRef $aIDs)
	Local $aClean[0]

	For $i = 0 To UBound($aIDs) - 1
		Local $sID = StringStripWS($aIDs[$i], 3)
		If $sID = "" Then ContinueLoop
		If Not StringRegExp($sID, "^[A-Za-z0-9_-]+$") Then ContinueLoop

		Local $bDuplicate = False
		For $j = 0 To UBound($aClean) - 1
			If StringLower($aClean[$j]) = StringLower($sID) Then
				$bDuplicate = True
				ExitLoop
			EndIf
		Next

		If Not $bDuplicate Then _ArrayAdd($aClean, $sID)
	Next

	Return $aClean
EndFunc

Func _GetConfig()
	; Read hotkey setting
	$configHotkey = StringStripWS(IniRead($configPath, "general", "hotkey", "{NUMPADSUB}"), 3)
	If $configHotkey = "" Then $configHotkey = "{NUMPADSUB}"

	; Read cursor lock settings as strict 0/1 values
	$configLockCursorFullscreen = _ReadConfigBool("cursor", "lock_cursor_fullscreen", 1)
	$configLockCursorWindowed = _ReadConfigBool("cursor", "lock_cursor_windowed", 1)
	$configLockCursorAllTitles = _ReadConfigBool("cursor", "lock_all_titles", 1)
	$configAutoLockFullscreenGames = _ReadConfigBool("cursor", "auto_lock_fullscreen_games", 0)
	$configAutoLockFullscreenBrowsers = _ReadConfigBool("cursor", "auto_lock_fullscreen_browsers", 0)

	; Read notification settings as strict 0/1 values
	$configSplashMessages = _ReadConfigBool("notifications", "splash_messages", 1)
	$configBrowserMessages = _ReadConfigBool("notifications", "browser_messages", 1)
	$configGameMessages = _ReadConfigBool("notifications", "game_messages", 1)

	; Validate the configured startup hotkey even though normal registration is
	; deferred until an eligible browser/game is active
	Local $result
	If $currentHotkey = "" Then
		$result = HotKeySet($configHotkey, "ToggleCursorLock")
		If $result = 0 Then
			MsgBox(16, "HotKey Error", "Configured hotkey '" & $configHotkey & "' could not be set. Reverting to default '{NUMPADSUB}'.")
			$configHotkey = "{NUMPADSUB}"
			$result = HotKeySet($configHotkey, "ToggleCursorLock")
			If $result = 0 Then
				MsgBox(16, "HotKey Error", "Default hotkey '{NUMPADSUB}' could not be set.")
			Else
				; Validation only; normal window detection registers it when needed
				HotKeySet($configHotkey)
			EndIf
		Else
			; Validation only; normal window detection registers it when needed
			HotKeySet($configHotkey)
		EndIf
	ElseIf $currentHotkey <> $configHotkey Then
		; If there's an existing hotkey, remove it before setting a new one
		HotKeySet($currentHotkey)

		; Attempt to set new hotkey
		$result = HotKeySet($configHotkey, "ToggleCursorLock")
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

	; Read and validate message duration (default 2000 ms), matching Settings limits
	$configDuration = Int(Number(IniRead($configPath, "message", "duration", "2000")))
	If $configDuration <= 0 Then $configDuration = 2000
	If $configDuration > 120000 Then $configDuration = 120000

	; Read and validate font family (default "Arial")
	$configFont = StringStripWS(IniRead($configPath, "message", "fontfamily", "Arial"), 3)
	If $configFont = "" Then $configFont = "Arial"

	; Validate both the configured family and the actual font object at the requested size
	Local $hTestFamily = _GDIPlus_FontFamilyCreate($configFont)
	If @error Or $hTestFamily = 0 Then
		MsgBox(16, "Font Error", "Configured font '" & $configFont & "' does not exist. Reverting to default 'Arial'.")
		$configFont = "Arial"
		$hTestFamily = _GDIPlus_FontFamilyCreate($configFont)
	EndIf

	If $hTestFamily <> 0 Then
		Local $hTestFont = _GDIPlus_FontCreate($hTestFamily, $configFontSize, 0)
		If @error Or $hTestFont = 0 Then
			If $hTestFont <> 0 Then _GDIPlus_FontDispose($hTestFont)
			MsgBox(16, "Font Error", "Configured font size '" & $configFontSize & "' could not be created. Reverting to default 24.")
			$configFontSize = 24
		Else
			_GDIPlus_FontDispose($hTestFont)
		EndIf

		_GDIPlus_FontFamilyDispose($hTestFamily)
	Else
		; Extremely defensive fallback if even the default family cannot be created
		$configFont = "Arial"
		$configFontSize = 24
	EndIf

	; Read and validate message opacity (default 150)
	$configOpacity = Int(Number(IniRead($configPath, "message", "opacity", "150")))
	If $configOpacity <= 0 Then $configOpacity = 150
	If $configOpacity >= 256 Then $configOpacity = 255

	; ========== ========== ==========

	; Default browser data (used if missing from INI)
	Local $defaultBrowsers = "brave,chrome,firefox,edge,opera"
	Local $defaultBrowserData = _
		[ _
			["brave", "Brave", ".*Brave$", "77,0,0,0", "4,0,0,0"], _
			["chrome", "Chrome", ".*Google Chrome$", "83,0,0,0", "4,0,0,0"], _
			["firefox", "Firefox", ".*Mozilla Firefox$", "81,0,0,0", "1,0,0,0"], _
			["edge", "Edge", ".*Microsoft\s*.*Edge$", "70,0,0,0", "1,0,0,0"], _
			["opera", "Opera", ".*Opera$", "83,4,4,56", "0,0,0,0"] _
		]

	; Read browser IDs from the INI file
	; A reserved | value means the user intentionally configured an empty list;
	; a missing/blank or wholly malformed non-sentinel value uses defaults
	Local $sBrowsers = IniRead($configPath, "browsers", "ids", $defaultBrowsers)
	Local $aBrowserIDs

	If StringStripWS($sBrowsers, 3) = "|" Then
		Local $aEmptyBrowserIDs[0]
		$aBrowserIDs = $aEmptyBrowserIDs
	Else
		If StringStripWS($sBrowsers, 3) = "" Then $sBrowsers = $defaultBrowsers

		; Convert to an array and remove blank, malformed, or duplicate IDs
		Local $aRawBrowserIDs = StringSplit($sBrowsers, ",", 2)
		$aBrowserIDs = _CompactConfigIDs($aRawBrowserIDs)

		If UBound($aBrowserIDs) = 0 Then
			Local $aDefaultBrowserIDs = StringSplit($defaultBrowsers, ",", 2)
			$aBrowserIDs = _CompactConfigIDs($aDefaultBrowserIDs)
		EndIf
	EndIf

	; Initialize browsers array
	Global $g_aBrowsers[UBound($aBrowserIDs)][5]

	; Loop through browser IDs and fetch data
	For $i = 0 To UBound($aBrowserIDs) - 1
		Local $browserID = StringStripWS($aBrowserIDs[$i], 3)
		If $browserID = "" Then ContinueLoop

		; Find default values (if any)
		; Unknown custom IDs use a safely escaped,
		; anchored literal as their fallback title expression.
		Local $defaultDisplay = $browserID
		Local $defaultTitle = "^" & _RegexEscapeLiteral($browserID) & "$"
		Local $defaultWindowOffsets = "0,0,0,0"
		Local $defaultFullOffsets = "0,0,0,0"

		For $j = 0 To UBound($defaultBrowserData) - 1
			If StringLower($defaultBrowserData[$j][0]) = StringLower($browserID) Then
				$defaultDisplay = $defaultBrowserData[$j][1]
				$defaultTitle = $defaultBrowserData[$j][2]
				$defaultWindowOffsets = $defaultBrowserData[$j][3]
				$defaultFullOffsets = $defaultBrowserData[$j][4]
				ExitLoop
			EndIf
		Next

		; Read browser display name, falling back if a hand-edited INI made it blank
		Local $browserDisplay = StringStripWS(IniRead($configPath, $browserID & "_browser", "name", $defaultDisplay), 3)
		If $browserDisplay = "" Then $browserDisplay = $defaultDisplay

		; Read browser title regex and validate the exact expression used by ProcessWindow
		Local $browserTitle = StringStripWS(IniRead($configPath, $browserID & "_browser", "title", $defaultTitle), 3)
		If Not _IsValidRegex($browserTitle) Then $browserTitle = $defaultTitle

		; Normalize all loaded browser offsets with the same signed-int32 rules as Settings
		Local $sWindowOffsets = _NormalizeOffsetString( _
			IniRead($configPath, $browserID & "_browser", "windowed_offsets", $defaultWindowOffsets), _
			$defaultWindowOffsets _
		)
		Local $sFullOffsets = _NormalizeOffsetString( _
			IniRead($configPath, $browserID & "_browser", "fullscreen_offsets", $defaultFullOffsets), _
			$defaultFullOffsets _
		)

		; Store the browser
		$g_aBrowsers[$i][0] = $browserID
		$g_aBrowsers[$i][1] = $browserDisplay
		$g_aBrowsers[$i][2] = $browserTitle
		$g_aBrowsers[$i][3] = $sWindowOffsets
		$g_aBrowsers[$i][4] = $sFullOffsets
	Next

	; ========== ========== ==========

	; Default game data (used if missing from INI)
	Local $defaultGames = "agar,diep,digdig,paper2,snake,wormate"
	Local $defaultGamesData = _
		[ _
			["agar", "Agar.io", "(?i)agar.io", "0,0,90,0", "0,0,90,0"], _
			["diep", "Diep", "(?i)diep.io", "0,0,0,0", "0,0,0,0"], _
			["digdig", "Digdig", "(?i)digdig.io", "0,0,0,0", "0,0,0,0"], _
			["paper2", "Paper 2", "(?i)paper", "0,0,0,0", "0,0,0,0"], _
			["snake", "Snake", "(?i)snake.io", "0,0,0,0", "0,0,0,0"], _
			["wormate", "Wormate", "(?i)wormate.io", "0,0,0,0", "0,0,0,0"] _
		]

	; Read game IDs from the INI file
	; A reserved | value means the user intentionally configured
	; an empty list; a missing/blank value still uses defaults
	Local $sGames = IniRead($configPath, "games", "ids", $defaultGames)
	Local $aGameIDs

	If StringStripWS($sGames, 3) = "|" Then
		Local $aEmptyGameIDs[0]
		$aGameIDs = $aEmptyGameIDs
	Else
		If StringStripWS($sGames, 3) = "" Then $sGames = $defaultGames

		; Convert to an array and remove blank, malformed, or duplicate IDs
		Local $aRawGameIDs = StringSplit($sGames, ",", 2)
		$aGameIDs = _CompactConfigIDs($aRawGameIDs)

		If UBound($aGameIDs) = 0 Then
			Local $aDefaultGameIDs = StringSplit($defaultGames, ",", 2)
			$aGameIDs = _CompactConfigIDs($aDefaultGameIDs)
		EndIf
	EndIf

	; Initialize games array
	Global $g_aGames[UBound($aGameIDs)][5]

	; Loop through game IDs and fetch data
	For $i = 0 To UBound($aGameIDs) - 1
		Local $gameID = StringStripWS($aGameIDs[$i], 3)
		If $gameID = "" Then ContinueLoop

		; Find default values (if any)
		; Unknown custom IDs use a safely escaped,
		; anchored literal as their fallback title expression.
		Local $defaultDisplay = $gameID
		Local $defaultTitle = "^" & _RegexEscapeLiteral($gameID) & "$"
		Local $defaultWindowOffsets = "0,0,0,0"
		Local $defaultFullOffsets = "0,0,0,0"

		For $j = 0 To UBound($defaultGamesData) - 1
			If StringLower($defaultGamesData[$j][0]) = StringLower($gameID) Then
				$defaultDisplay = $defaultGamesData[$j][1]
				$defaultTitle = $defaultGamesData[$j][2]
				$defaultWindowOffsets = $defaultGamesData[$j][3]
				$defaultFullOffsets = $defaultGamesData[$j][4]
				ExitLoop
			EndIf
		Next

		; Read game display name, falling back if a hand-edited INI made it blank
		Local $gameDisplay = StringStripWS(IniRead($configPath, $gameID & "_game", "name", $defaultDisplay), 3)
		If $gameDisplay = "" Then $gameDisplay = $defaultDisplay

		; Read game title regex and validate the exact expression used by ProcessWindow
		Local $gameTitle = StringStripWS(IniRead($configPath, $gameID & "_game", "title", $defaultTitle), 3)
		If Not _IsValidRegex($gameTitle) Then $gameTitle = $defaultTitle

		; Normalize all loaded game offsets with the same signed-int32 rules as Settings
		Local $sWindowOffsets = _NormalizeOffsetString( _
			IniRead($configPath, $gameID & "_game", "windowed_offsets", $defaultWindowOffsets), _
			$defaultWindowOffsets _
		)
		Local $sFullOffsets = _NormalizeOffsetString( _
			IniRead($configPath, $gameID & "_game", "fullscreen_offsets", $defaultFullOffsets), _
			$defaultFullOffsets _
		)

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

Func _CaptureHotkey($hInput, $hButton, $hCancel, ByRef $aLockedControls)
	Local $sLastValidHotkey = ""
	Local $iLastValidChordSize = 0
	Local $sOriginalHotkey = GUICtrlRead($hInput)
	Local $iExitReason = 0 ; 1 = cancel capture, 2 = close Settings, 3 = valid capture

	; Remember which controls were enabled before capture, then freeze them.
	; Controls that were already disabled remain disabled after capture finishes.
	Local $aWasEnabled[UBound($aLockedControls)]
	For $i = 0 To UBound($aLockedControls) - 1
		$aWasEnabled[$i] = BitAND(GUICtrlGetState($aLockedControls[$i]), $GUI_DISABLE) = 0
		GUICtrlSetState($aLockedControls[$i], $GUI_DISABLE)
	Next

	$bCapturing = True

	GUICtrlSetData($hInput, "")
	GUICtrlSetBkColor($hInput, 0xFFFF00) ; Yellow glow to indicate active capture
	GUICtrlSetData($hButton, "Cancel Capture")
	GUICtrlSetState($hInput, $GUI_FOCUS) ; Keep Space/Enter from re-triggering the capture button

	While $bCapturing
		; Keep About and the essential Settings actions responsive while capture
		; owns this modal loop
		; Other Settings controls are disabled above
		Local $aCaptureMsg = GUIGetMsg(1)
		Local $iCaptureMsgID = $aCaptureMsg[0]
		Local $hCaptureMsgSource = $aCaptureMsg[1]

		If $bAbout And _ProcessAboutMessage($iCaptureMsgID, $hCaptureMsgSource) Then
			Sleep(10)
			ContinueLoop
		EndIf

		If $hCaptureMsgSource = $hConfigGUI Then
			Switch $iCaptureMsgID
				Case $hButton
					; Second click explicitly cancels capture and restores the old hotkey
					$iExitReason = 1
					ExitLoop

				Case $GUI_EVENT_CLOSE, $hCancel
					; Let the caller close Settings normally after capture unwinds
					$iExitReason = 2
					ExitLoop
			EndSwitch
		EndIf

		Dim $pressedKeys[0] ; Initialize fresh for each loop iteration
		Dim $modifiers[0], $regularKeys[0]

		; Detect multiple key presses
		For $i = 1 To 255
			; Skip mouse buttons
			If $i = 0x01 Or $i = 0x02 Or $i = 0x04 Or $i = 0x05 Or $i = 0x06 Then ContinueLoop
			If $i = 0x7B Then ContinueLoop ; Skip F12

			If _IsPressed(Hex($i, 2)) Then
				Local $keyName = _GetKeyName(Hex($i, 2))
				If $keyName <> "" And Not _ArrayContains($pressedKeys, $keyName) Then
					_ArrayAdd($pressedKeys, $keyName)
				EndIf
			EndIf
		Next

		; A capture only completes after a valid base key was seen and all keys are released
		; Modifier-only combinations remain in capture mode
		If UBound($pressedKeys) = 0 And $sLastValidHotkey <> "" Then
			$iExitReason = 3
			ExitLoop
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
			Local $sCurrentCaptured = _StringJoin($orderedKeys, " + ")
			Local $sConvertedHotkey = ConvertToHotkeyString($sCurrentCaptured)

			; ConvertToHotkeyString returns blank when only modifiers are held
			; Once a valid chord is seen, never downgrade it while keys are being released
			; This preserves Ctrl+A regardless of release order
			If $sConvertedHotkey <> "" Then
				Local $iCurrentChordSize = UBound($modifiers) + 1 ; modifiers + one base key
				If $iCurrentChordSize >= $iLastValidChordSize Then
					$sLastValidHotkey = $sConvertedHotkey
					$iLastValidChordSize = $iCurrentChordSize
					GUICtrlSetData($hInput, $sLastValidHotkey)
				EndIf
			ElseIf $sLastValidHotkey = "" Then
				GUICtrlSetData($hInput, "")
			EndIf
		EndIf

		Sleep(100)
	WEnd

	$bCapturing = False

	; Restore the exact enabled/disabled state each Settings control had before capture
	For $i = 0 To UBound($aLockedControls) - 1
		If $aWasEnabled[$i] Then GUICtrlSetState($aLockedControls[$i], $GUI_ENABLE)
	Next

	GUICtrlSetBkColor($hInput, _WinAPI_GetSysColor($COLOR_WINDOW))
	GUICtrlSetData($hButton, "Start Capture")

	Switch $iExitReason
		Case 3
			GUICtrlSetData($hInput, $sLastValidHotkey)
			Return SetError(0, 0, True)

		Case 2
			GUICtrlSetData($hInput, $sOriginalHotkey)
			Return SetError(1, 0, False)

		Case Else
			GUICtrlSetData($hInput, $sOriginalHotkey)
			Return SetError(0, 0, False)
	EndSwitch
EndFunc

; This function removes generic keys (e.g., "ALT") if a side-specific one exists (e.g., "LALT" or "RALT")
Func _FilterModifiers(ByRef $modifiers)
	Local $filtered[0]

	If _ArrayContains($modifiers, "CTRL") Or _ArrayContains($modifiers, "LCTRL") Or _ArrayContains($modifiers, "RCTRL") Then _
		_ArrayAdd($filtered, "CTRL")
	If _ArrayContains($modifiers, "ALT") Or _ArrayContains($modifiers, "LALT") Or _ArrayContains($modifiers, "RALT") Then _
		_ArrayAdd($filtered, "ALT")
	If _ArrayContains($modifiers, "SHIFT") Or _ArrayContains($modifiers, "LSHIFT") Or _ArrayContains($modifiers, "RSHIFT") Then _
		_ArrayAdd($filtered, "SHIFT")
	If _ArrayContains($modifiers, "WIN") Or _ArrayContains($modifiers, "LWIN") Or _ArrayContains($modifiers, "RWIN") Then _
		_ArrayAdd($filtered, "WIN")

	Return $filtered
EndFunc

Func _InitKeyMap()
	If IsObj($g_oKeyMap) Then Return

	$g_oKeyMap = ObjCreate("Scripting.Dictionary")

	; Mouse Buttons
	;$g_oKeyMap.Add("01", "LMB")
	;$g_oKeyMap.Add("02", "RMB")
	;$g_oKeyMap.Add("04", "MMB")
	;$g_oKeyMap.Add("05", "MB4")
	;$g_oKeyMap.Add("06", "MB5")

	; Common Keys
	$g_oKeyMap.Add("03", "BREAK") ; CANCEL
	$g_oKeyMap.Add("08", "BACKSPACE")
	$g_oKeyMap.Add("09", "TAB")
	$g_oKeyMap.Add("0D", "ENTER")
	$g_oKeyMap.Add("10", "SHIFT")
	$g_oKeyMap.Add("11", "CTRL")
	$g_oKeyMap.Add("12", "ALT")
	$g_oKeyMap.Add("1B", "ESC")
	$g_oKeyMap.Add("20", "SPACE")
	$g_oKeyMap.Add("5B", "LWIN")
	$g_oKeyMap.Add("5C", "RWIN")

	; Additional Navigation Keys
	$g_oKeyMap.Add("21", "PGUP")
	$g_oKeyMap.Add("22", "PGDN")
	$g_oKeyMap.Add("23", "END")
	$g_oKeyMap.Add("24", "HOME")
	$g_oKeyMap.Add("25", "LEFT")
	$g_oKeyMap.Add("26", "UP")
	$g_oKeyMap.Add("27", "RIGHT")
	$g_oKeyMap.Add("28", "DOWN")
	$g_oKeyMap.Add("2D", "INSERT")
	$g_oKeyMap.Add("2E", "DELETE")

	; Additional System Keys
	$g_oKeyMap.Add("2C", "PRINTSCREEN") ; PRTSC
	$g_oKeyMap.Add("13", "PAUSE")
	$g_oKeyMap.Add("14", "CAPSLOCK")
	$g_oKeyMap.Add("90", "NUMLOCK")
	$g_oKeyMap.Add("91", "SCROLLLOCK")
	$g_oKeyMap.Add("5D", "APPSKEY") ; APPS

	; Numpad Keys
	$g_oKeyMap.Add("60", "NUMPAD0")
	$g_oKeyMap.Add("61", "NUMPAD1")
	$g_oKeyMap.Add("62", "NUMPAD2")
	$g_oKeyMap.Add("63", "NUMPAD3")
	$g_oKeyMap.Add("64", "NUMPAD4")
	$g_oKeyMap.Add("65", "NUMPAD5")
	$g_oKeyMap.Add("66", "NUMPAD6")
	$g_oKeyMap.Add("67", "NUMPAD7")
	$g_oKeyMap.Add("68", "NUMPAD8")
	$g_oKeyMap.Add("69", "NUMPAD9")
	$g_oKeyMap.Add("6A", "NUMPADMULT")
	$g_oKeyMap.Add("6B", "NUMPADADD")
	$g_oKeyMap.Add("6D", "NUMPADSUB")
	$g_oKeyMap.Add("6E", "NUMPADDOT")		 ; NUMPADDECIMAL
	$g_oKeyMap.Add("6F", "NUMPADDIV")

	; OEM / Punctuation Keys
	$g_oKeyMap.Add("BA", ";")						; SEMICOLON, VK_OEM_1 (e.g., ;)
	$g_oKeyMap.Add("BB", "=")						; EQUALS, VK_OEM_PLUS (e.g., =)
	$g_oKeyMap.Add("BC", ",")						; COMMA, VK_OEM_COMMA (e.g., ,)
	$g_oKeyMap.Add("BD", "-")						; MINUS, VK_OEM_MINUS (e.g., -)
	$g_oKeyMap.Add("BE", ".")							; PERIOD, VK_OEM_PERIOD (e.g., .)
	$g_oKeyMap.Add("BF", "/")							; FORWARD_SLASH, VK_OEM_2 (e.g., /)
	$g_oKeyMap.Add("C0", "`")						; TILDE, VK_OEM_3 (e.g., ~ or `)
	$g_oKeyMap.Add("DB", "[")						; OPEN_BRACKET, VK_OEM_4 (e.g., [)
	$g_oKeyMap.Add("DC", "\")						; BACKSLASH, VK_OEM_5 (e.g., \)
	$g_oKeyMap.Add("DD", "]")						; CLOSE_BRACKET, VK_OEM_6 (e.g., ])
	$g_oKeyMap.Add("DE", "'")							; APOSTROPHE, VK_OEM_7 (e.g., ')
	;$g_oKeyMap.Add("DF", "OEM_8")				; Layout-specific/unsupported

	; Media / Special Function Keys
	;$g_oKeyMap.Add("AD", "VOLUME_MUTE")		; Volume Mute
	;$g_oKeyMap.Add("AE", "VOLUME_DOWN")		; Volume Down
	;$g_oKeyMap.Add("AF", "VOLUME_UP")			; Volume Up
	;$g_oKeyMap.Add("B0", "NEXT_TRACK")			; Next Track
	;$g_oKeyMap.Add("B1", "PREV_TRACK")			; Previous Track
	;$g_oKeyMap.Add("B2", "STOP")						; Stop
	;$g_oKeyMap.Add("B3", "PLAY_PAUSE")			; Play/Pause

	; Additional Special Keys
	;$g_oKeyMap.Add("0C", "CLEAR")					; Clear key (often on numpad)
	;$g_oKeyMap.Add("29", "SELECT")					; Select key
	;$g_oKeyMap.Add("5F", "SLEEP")					; Sleep key

	; Browser Keys
	;$g_oKeyMap.Add("A6", "BROWSER_BACK")
	;$g_oKeyMap.Add("A7", "BROWSER_FORWARD")
	;$g_oKeyMap.Add("A8", "BROWSER_REFRESH")
	;$g_oKeyMap.Add("A9", "BROWSER_STOP")
	;$g_oKeyMap.Add("AA", "BROWSER_SEARCH")
	;$g_oKeyMap.Add("AB", "BROWSER_FAVORITES")
	;$g_oKeyMap.Add("AC", "BROWSER_HOME")

	; Launch/Application Keys
	;$g_oKeyMap.Add("B4", "LAUNCH_MAIL")
	;$g_oKeyMap.Add("B5", "LAUNCH_MEDIA_SELECT")
	;$g_oKeyMap.Add("B6", "LAUNCH_APP1")		; Often used for Calculator
	;$g_oKeyMap.Add("B7", "LAUNCH_APP2")		; Additional launch key

	; Additional OEM / Special Keys
	;$g_oKeyMap.Add("E1", "OEM_AX")
	;$g_oKeyMap.Add("E2", "OEM_102")
	;$g_oKeyMap.Add("E5", "PROCESSKEY")

	; Additional Rare Keys
	;$g_oKeyMap.Add("F6", "ATTN")
	;$g_oKeyMap.Add("F7", "CRSEL")
	;$g_oKeyMap.Add("F8", "EXSEL")
	;$g_oKeyMap.Add("F9", "EREOF")
	;$g_oKeyMap.Add("FA", "PLAY")
	;$g_oKeyMap.Add("FB", "ZOOM")
	;$g_oKeyMap.Add("FC", "NONAME")
	;$g_oKeyMap.Add("FD", "PA1")
	;$g_oKeyMap.Add("FE", "OEM_CLEAR")

	; Numbers
	For $i = 0 To 9
		$g_oKeyMap.Add(Hex(48 + $i, 2), String($i))
	Next

	; Letters
	For $i = 0 To 25
		$g_oKeyMap.Add(Hex(65 + $i, 2), Chr(65 + $i))
	Next

	; Function keys
	For $i = 1 To 24
		If $i = 12 Then ContinueLoop ; Skip F12 since it's reserved by Windows
		$g_oKeyMap.Add(Hex(111 + $i, 2), "F" & $i)
	Next

	; Modifier Keys
	$g_oKeyMap.Add("A0", "LSHIFT")
	$g_oKeyMap.Add("A1", "RSHIFT")
	$g_oKeyMap.Add("A2", "LCTRL")
	$g_oKeyMap.Add("A3", "RCTRL")
	$g_oKeyMap.Add("A4", "LALT")
	$g_oKeyMap.Add("A5", "RALT")
EndFunc

Func _GetKeyName($hexKey)
	_InitKeyMap()

	If IsObj($g_oKeyMap) And $g_oKeyMap.Exists($hexKey) Then
		Return $g_oKeyMap.Item($hexKey)
	EndIf

	; Unsupported virtual keys are ignored instead of being turned into an
	; invalid {KEY_XX} HotKeySet token
	Return ""
	; Return "KEY_" & $hexKey
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
	If Not $bBaseFound Then Return ""
	Return $sHotkey
EndFunc

#EndRegion
; =====

; ========== ========== ========== ========== ==========

_Main()