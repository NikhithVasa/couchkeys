on mirroringPanelVisible()
    tell application "System Events"
        tell process "ControlCenter"
            if not (exists window 1) then return false
            return exists static text "Screen Mirroring" of group 1 of window 1
        end tell
    end tell
end mirroringPanelVisible

on waitForMirroringPanel()
    repeat 40 times
        if my mirroringPanelVisible() then return "Screen Mirroring picker opened."
        delay 0.05
    end repeat
    error "macOS did not expose the Screen Mirroring picker. Open Control Center > Screen Mirroring manually." number 2001
end waitForMirroringPanel

tell application "System Events"
    if not UI elements enabled then
        error "Accessibility permission is required to open the picker automatically. Use Control Center > Screen Mirroring manually, or grant permission in System Settings > Privacy & Security > Accessibility." number 2002
    end if
    tell process "ControlCenter"
        set controlCenterItem to first menu bar item of menu bar 1 whose description is "Control Center"
        repeat 3 times
            if my mirroringPanelVisible() then return "Screen Mirroring picker is already open."
            if exists window 1 then
                if exists group 1 of window 1 then
                    repeat with controlItem in every checkbox of group 1 of window 1
                        try
                            set identifier to value of attribute "AXIdentifier" of controlItem
                        on error
                            set identifier to missing value
                        end try
                        if identifier is "controlcenter-screen-mirroring" then
                            click controlItem
                            return my waitForMirroringPanel()
                        end if
                    end repeat
                end if
                click controlCenterItem
                repeat 20 times
                    if not (exists window 1) then exit repeat
                    delay 0.05
                end repeat
            else
                click controlCenterItem
                repeat 20 times
                    if exists window 1 then exit repeat
                    delay 0.05
                end repeat
            end if
        end repeat
    end tell
end tell
error "Cannot find the Screen Mirroring control on this macOS version. Open Control Center > Screen Mirroring manually." number 2003
