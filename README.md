# USBMap

Python script for mapping USB ports in macOS and creating a custom injector kext.

***

# Features

- [x] No dependency on USBInjectAll
- [x] Can map XHCI (chipset, third party, and AMD), EHCI, OHCI, and UHCI ports
- [ ] ~~Can map USB 2 HUBs~~ *currently disabled*
- [x] Matches based on class name, not port or controller name
- [x] Allows setting nicknames to the last-seen populated ports in discovery
- [x] Aggregates connected devices via session id instead of the broken port addressing
- [x] Can use best-guess approaches to generate ACPI to rename controllers or reset RHUB devices as needed

***

## Installation

### With Git

Run the following one line at a time in Terminal:

    git clone https://github.com/corpnewt/USBMap
    cd USBMap
    chmod +x USBMap.command
    
Then run with either `./USBMap.command` or by double-clicking *USBMap.command*

### Without Git

You can get the latest zip of this repo [here](https://github.com/corpnewt/USBMap/archive/master.zip).  Then run by double-clicking *USBMap.command*

***
