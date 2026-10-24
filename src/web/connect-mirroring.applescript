on run arguments
    if (count of arguments) is not 2 then error "Expected the receiver ID and picker helper path." number 2010
    set targetIdentifier to "screen-mirroring-device-AirPlay:" & item 1 of arguments
    set browserReady to false
    set activationRequested to false
    tell application "System Events"
        repeat 60 times
            if exists process "Safari" then
                tell process "Safari"
                    if not activationRequested then
                        set frontmost to true
                        set activationRequested to true
                    end if
                    if frontmost and (exists window 1) then
                        set browserReady to true
                        exit repeat
                    end if
                end tell
            end if
            delay 0.05
        end repeat
    end tell
    if not browserReady then error "Safari did not become ready; no AirPlay receiver was selected." number 2012
    run script (POSIX file (item 2 of arguments))
    tell application "System Events"
        tell process "ControlCenter"
            repeat 40 times
                if exists group 1 of scroll area 1 of group 1 of window 1 then
                    if exists static text "Currently Mirroring" of group 1 of scroll area 1 of group 1 of window 1 then
                        repeat with activeReceiver in every button of group 1 of scroll area 1 of group 1 of window 1
                            try
                                set activeIdentifier to value of attribute "AXIdentifier" of activeReceiver
                            on error
                                set activeIdentifier to missing value
                            end try
                            if activeIdentifier is targetIdentifier then
                                key code 53
                                repeat 20 times
                                    if not (exists window 1) then exit repeat
                                    delay 0.05
                                end repeat
                                if exists window 1 then error "Close the macOS picker before typing in Safari." number 2013
                                tell application "System Events" to set frontmost of process "Safari" to true
                                return "already_connected"
                            end if
                        end repeat
                    end if
                    repeat with receiverControl in every checkbox of group 1 of scroll area 1 of group 1 of window 1
                        try
                            set receiverIdentifier to value of attribute "AXIdentifier" of receiverControl
                        on error
                            set receiverIdentifier to missing value
                        end try
                        if receiverIdentifier is targetIdentifier then
                            if value of receiverControl is 1 then
                                return "connection_requested"
                            end if
                            click receiverControl
                            return "connection_requested"
                        end if
                    end repeat
                end if
                delay 0.05
            end repeat
        end tell
    end tell
    error "The verified TCL AirPlay receiver is not currently in the Mac picker. No other receiver was selected." number 2011
end run
