#cs ----------------------------------------------------------------------------
Script Name: Browser Cursor Lock
Author: Brogan Scott Houston McIntyre	
Version: 0.1.0
Date: 2025-02-18
License: MIT
#ce ----------------------------------------------------------------------------

#pragma compile(Out, "Cursor Lock.exe")

#include <GDIPlus.au3>
#include <GuiConstants.au3>
#include <WindowsConstants.au3>
#include <WinAPI.au3>
#include <Math.au3>
#include <TrayConstants.au3>
#include <WinAPIRes.au3>

Global Const $GDIP_TEXTRENDERINGHINT_CLEARTYPEGRIDFIT = 5
Global Const $GDIP_STRINGFORMAT_GENERICTYPOGRAPHIC = 0x00000001

; ==========

Global $g_szMutexName = "Browser Cursor Lock"
Global $g_hMutex = _Singleton($g_szMutexName, 1)

If @error Then
	MsgBox(16, "Error", "Another instance is already running.")
	Exit
EndIf

; ========== ========== ========== ========== ==========

Global $gameTitles = ["Paper.io 2", "Paper.io play online", "Play Snake Online | Snake.io"]

; ========== ========== ========== ========== ==========

Global $shutdown = False

Global $g_hActiveGameWnd = 0
Global $g_bCursorLocked = False

Global $browser = False
Global $game = False
Global $displayText =  ""
Global $display = 200
Global $activeWindow = 0

Global $hMessageGUI = 0
Global $hMessageLabel = 0

Global $currentWidth = 0
Global $currentHeight = 0

HotKeySet("{NUMPADSUB}", "ToggleCursorLock")

OnAutoItExitRegister("Unload")

; ========== ========== ========== ========== ==========

Opt("TrayMenuMode", 3)
TraySetToolTip("Browser Cursor Lock")
Global $exitItem = TrayCreateItem("Exit Script")

; ========== ========== ========== ========== ==========

Func _Main()
	_GDIPlus_Startup()

	; =====

	$displayText = "Browser Cursor Lock"

	Local $activeWindow = 0
	Local $lastHyphenPos = 0
	Local $titleBeforeHyphen = ""
	Local $titleAfterHyphen = ""
	Local $isGameTitle = False

	; =====

	While $shutdown = False
		$currentWindow = WinGetTitle("[ACTIVE]")

		; ========== ========== ==========

		ProcessWindowTitle($currentWindow)

		; ========== ========== ==========

		If StringLen($displayText) > 0 Then
			DisplayMessage($displayText)
			$display = BitOR($display, 100)
			$displayText = ""
			Sleep(10)
		Else
			If $hMessageGUI <> 0 Then
				$display = $display - 1
				If $display > 0 Then
					Sleep(10)
				Else
					GUIDelete($hMessageGUI)
					$hMessageGUI = 0
					$hMessageLabel = 0
					Sleep(100)
				EndIf
			Else
				Sleep(100)
			EndIf
		EndIf
		
		; ========== ========== ==========
		
		Switch TrayGetMsg()
			Case $exitItem
				ExitScript()
		EndSwitch
	WEnd
EndFunc

; ==========

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

; ==========

Func Unload()
	_GDIPlus_Shutdown()
	$shutdown = True
EndFunc

; ========== ========== ========== ========== ==========

Func ProcessWindowTitle($currentWindow)
    Local $lastHyphenPos = StringInStr($currentWindow, "-", 0, -1)
    If $lastHyphenPos = 0 Then $lastHyphenPos = StringInStr($currentWindow, "–", 0, -1) ; En dash
    If $lastHyphenPos = 0 Then $lastHyphenPos = StringInStr($currentWindow, "—", 0, -1) ; Em dash

    If $lastHyphenPos > 0 Then
        Local $titleBeforeHyphen = StringTrimRight($currentWindow, StringLen($currentWindow) - $lastHyphenPos + 1)
        Local $titleAfterHyphen = StringTrimLeft($currentWindow, $lastHyphenPos + 1)

        If StringStripWS($titleAfterHyphen, 3) = "Brave" Or _
           StringStripWS($titleAfterHyphen, 3) = "Google Chrome" Or _
           StringStripWS($titleAfterHyphen, 3) = "Mozilla Firefox" Then

            Local $isGameTitle = False
            For $i = 0 To UBound($gameTitles) - 1
                If StringInStr($titleBeforeHyphen, $gameTitles[$i]) Then
                    $isGameTitle = True
                    ExitLoop
                EndIf
            Next

            If $browser = False Then
                If $isGameTitle Then
                    $game = True
                    $displayText = "Game detected: " & $titleBeforeHyphen
                    $g_hActiveGameWnd = WinGetHandle("[ACTIVE]")
                Else
                    $displayText = "Browser activated"
                EndIf
                $browser = True
            Else
                If $game = False Then
                    If $isGameTitle Then
                        $game = True
                        $displayText = "Game detected: " & $titleBeforeHyphen
                        $g_hActiveGameWnd = WinGetHandle("[ACTIVE]")
                    EndIf
                Else
                    If $isGameTitle = False Then
                        $displayText = "Game deactivated"
                        $game = False
                        $g_hActiveGameWnd = 0
                        If $g_bCursorLocked Then
                            ReleaseCursor()
                            $g_bCursorLocked = False
                            $displayText &= " and cursor unlocked"
                        EndIf
                    EndIf
                EndIf
            EndIf
        Else
            If $browser Then
                $displayText = "Browser deactivated"
                $browser = False
                $game = False
                $g_hActiveGameWnd = 0
                If $g_bCursorLocked Then
                    ReleaseCursor()
                    $g_bCursorLocked = False
                    $displayText &= " and cursor unlocked"
                EndIf
            EndIf
        EndIf
    Else
        If $browser Then
            $displayText = "Browser deactivated"
            $browser = False
            $game = False
            $g_hActiveGameWnd = 0
            If $g_bCursorLocked Then
                ReleaseCursor()
                $g_bCursorLocked = False
                $displayText &= " and cursor unlocked"
            EndIf
        EndIf
    EndIf
EndFunc

; ========== ========== ========== ========== ==========

Func ExitScript()
	$shutdown = True

	DisplayMessage("Goodbye!")
	Sleep(1000)

	If $hMessageGUI <> 0 Then
		GUIDelete($hMessageGUI)
		$hMessageGUI = 0
		$hMessageLabel = 0
	EndIf

	Exit
EndFunc

; ========== ========== ========== ========== ==========

Func _StringInPixelsByChar_gdip($hGraphic, $sString, $hFont, $tLayout)
	_GDIPlus_GraphicsSetTextRenderingHint($hGraphic, $GDIP_TEXTRENDERINGHINT_CLEARTYPEGRIDFIT)
	Local $hFormat = _GDIPlus_StringFormatCreate($GDIP_STRINGFORMAT_GENERICTYPOGRAPHIC)

	Local $totalWidth = 0
	Local $maxHeight = 0
	Local $aRanges[2][2] = [[1], [0, 1]]
	Local $aWidthHeight[2]

	Local $stringLength = StringLen($sString)
	For $i = 1 To $stringLength
		$aRanges[1][0] = $i - 1
		_GDIPlus_StringFormatSetMeasurableCharacterRanges($hFormat, $aRanges)
		Local $aRegions = _GDIPlus_GraphicsMeasureCharacterRanges($hGraphic, $sString, $hFont, $tLayout, $hFormat)
		Local $aBounds = _GDIPlus_RegionGetBounds($aRegions[1], $hGraphic)
		$totalWidth += $aBounds[2]
		$maxHeight = _Max($maxHeight, $aBounds[3])
		_GDIPlus_RegionDispose($aRegions[1])
	Next

	_GDIPlus_StringFormatDispose($hFormat)

	$aWidthHeight[0] = $totalWidth
	$aWidthHeight[1] = $maxHeight
	Return $aWidthHeight
EndFunc

; ==========

Func DisplayMessage($sText, $duration = 200)
	Local $hDC = _WinAPI_GetDC(0)
	Local $hGraphic = _GDIPlus_GraphicsCreateFromHDC($hDC)

	; Set up font and layout
	Local $hFamily = _GDIPlus_FontFamilyCreate("Arial")
	Local $hFont = _GDIPlus_FontCreate($hFamily, 24, 0)
	Local $tLayout = _GDIPlus_RectFCreate(0, 0, 400, 78)

	; Measure text size
	Local $aTextSize = _StringInPixelsByChar_gdip($hGraphic, $sText, $hFont, $tLayout)
	Local $iTextWidth = $aTextSize[0] + 40, $iTextHeight = $aTextSize[1] + 20

	$display = $duration

	_GDIPlus_GraphicsDispose($hGraphic)
	_WinAPI_ReleaseDC(0, $hDC)

	; Check if the GUI exists and update size only if changed
	If $hMessageGUI <> 0 Then
		If $currentWidth <> $iTextWidth Or $currentHeight <> $iTextHeight Then
			$currentWidth = $iTextWidth
			$currentHeight = $iTextHeight
			WinMove($hMessageGUI, "", (@DesktopWidth - $iTextWidth) / 2, (@DesktopHeight - $iTextHeight) / 2, $iTextWidth - 10, $iTextHeight)
			Local $hRegion = _WinAPI_CreateRoundRectRgn(0, 0, $iTextWidth - 8, $iTextHeight, 20, 20)
			_WinAPI_SetWindowRgn($hMessageGUI, $hRegion)
		EndIf
	Else
		; Create GUI if it doesn't exist
		$hMessageGUI = GUICreate("Browser Cursor Lock", $iTextWidth - 10, $iTextHeight, (@DesktopWidth - $iTextWidth) / 2, (@DesktopHeight - $iTextHeight) / 2, $WS_POPUP, BitOR($WS_EX_TOPMOST, $WS_EX_LAYERED, $WS_EX_TOOLWINDOW, $WS_EX_NOACTIVATE, $WS_EX_TRANSPARENT))
		
		WinSetTrans($hMessageGUI, "", 150)
		
		DllCall("user32.dll", "long", "SetWindowLong", "hwnd", $hMessageGUI, "int", $GWL_EXSTYLE, "long", BitOR($WS_EX_NOACTIVATE, $WS_EX_TOOLWINDOW, $WS_EX_TRANSPARENT, $WS_EX_LAYERED))
		WinSetOnTop($hMessageGUI, "", 1)
		; DllCall("user32.dll", "long", "SetWindowLong", "hwnd", $hMessageGUI, "int", $GWL_EXSTYLE, "long", BitOR($WS_EX_NOACTIVATE, $WS_EX_TRANSPARENT, $WS_EX_LAYERED))
		Local $hRegion = _WinAPI_CreateRoundRectRgn(0, 0, $iTextWidth - 8, $iTextHeight, 20, 20)
		_WinAPI_SetWindowRgn($hMessageGUI, $hRegion)
	EndIf

	; Delete and recreate the label text and dimensions
	If $hMessageLabel <> 0 Then
		GUICtrlDelete($hMessageLabel)
	EndIf
	$hMessageLabel = GuiCtrlCreateLabel($sText, 20, 10, $iTextWidth - 40, $iTextHeight - 20)
	GUICtrlSetFont($hMessageLabel, 24)

	; Set the GUI to be visible
	GuiSetState(@SW_SHOWNA, $hMessageGUI)

	; Dispose of font objects
	_GDIPlus_FontDispose($hFont)
	_GDIPlus_FontFamilyDispose($hFamily)
EndFunc

; ========== ========== ========== ========== ==========

Func ToggleCursorLock()
	If $g_hActiveGameWnd Then
		If $g_bCursorLocked Then
			$g_bCursorLocked = False
			ReleaseCursor()
			DisplayMessage("Cursor unlocked")
		Else
			$g_bCursorLocked = True
			ConfineCursorToWindow($g_hActiveGameWnd)
			DisplayMessage("Cursor locked to game window")
		EndIf
	Else
		DisplayMessage("No active game window detected")
	EndIf
EndFunc

Func ConfineCursorToWindow($hWnd)
	If Not $hWnd Then
		Return
	EndIf

	; Get window position and size
    Local $aPos = WinGetPos($hWnd)
	If @error Then
        Return
    EndIf

	; Get window borders
	Local $aBorders = GetWindowBorders($hWnd)
	If @error Then
        Return
    EndIf

    ; Adjust for borders to confine inside the client area
    Local $iLeft = $aPos[0] + $aBorders[3]
    Local $iTop = $aPos[1] + $aBorders[0] + 4
    Local $iRight = $iLeft + ($aPos[2] - $aBorders[1] - $aBorders[3])   ; Fix for right side
    Local $iBottom = $iTop + ($aPos[3] - $aBorders[0] - $aBorders[2]) - 4  ; Fix for bottom side

	; Create the clipping rectangle
    Local $tRect = _WinAPI_CreateRect($iLeft, $iTop, $iRight, $iBottom)
	
	; Apply cursor restriction
    _WinAPI_ClipCursor($tRect)
EndFunc

Func ReleaseCursor()
	_WinAPI_ClipCursor(0)
EndFunc

; ========== ========== ========== ========== ==========

Func GetWindowBorders($hWnd)
    If Not $hWnd Then Return SetError(1, 0, 0)

    ; Get full window position and size
    Local $aWinPos = WinGetPos($hWnd)  ; [X, Y, Width, Height]
    If @error Then Return SetError(2, 0, 0)

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
    Local $iLeftBorder = $iClientLeft - $aWinPos[0]
    Local $iTopBorder = $iClientTop - $aWinPos[1]
    Local $iRightBorder = ($aWinPos[2] - $iLeftBorder - $iClientWidth)
    Local $iBottomBorder = ($aWinPos[3] - $iTopBorder - $iClientHeight)

    ; Debug output
   ; ShowBorderDebug([$iLeftBorder, $iTopBorder, $iRightBorder, $iBottomBorder])

    ; Store results in an array and return
    ;Local $aBorders[4] = [$iLeftBorder, $iTopBorder, $iRightBorder, $iBottomBorder]
	Local $aBorders[4] = [$iTopBorder, $iRightBorder, $iBottomBorder, $iLeftBorder]
    Return $aBorders
EndFunc


; ========== ========== ========== ========== ==========

_Main()