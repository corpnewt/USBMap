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

# Index

- [Installation](#installation)
- [Vocab Lesson](#vocab-lesson)
- [What Is USB Mapping?](#what-is-usb-mapping)

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

## Vocab Lesson

*Before we even get started, let's get familiar with some words because vocabulary is **fun**!*

~~Scary~~ Word | Definition
---------- | ----------
`Port` | A physical connection where you can plug a USB devices.  This could be a USB port on a case, a USB-C port, etc.
`Header` | Similar to a `Port`, but typically on the motherboard itself.  These often take a special connector, and typically either have internal devices plugged in (AiO pump controllers, Bluetooth devices, etc), or extensions that lead to ports at the front of your case when used.
`Chipset` | The hardware on the motherboard responsible for "data flow" between components (on my Maximus X Code, this is Intel's Z370 chipset).
`Controller` | The hardware responsible for managing USB ports.
`RHUB` or `HUBN` | A software device that provides information for each individual port
`OHCI` and `UHCI` | USB 1.1/1.0 protocol - `OHCI` is the "open" variant of `UHCI`.  They both do roughly the same thing, but are not interchangable or compatible with each other.
`EHCI` | USB 2.0 protocol with 1.0/1.1 backward compatibility.
`XHCI` | USB protocol used for USB 3 and newer - can emulate USB 2.0/1.1/1.0, but is a completely different protocol.
`Port Personality` | A software representation of a USB port.  May correspond to a physical `port`, internal `header`, or may be orphaned.
`Mapping` | In this context, the process of determining which `port personalities` correspond to which `ports` on which `controllers`.
`Full Speed`/`Low Speed` | USB 1.x
`High Speed` | USB 2.0
`Super Speed` | USB 3+

***

## What Is USB Mapping?

*Alright kids, get out your cartography kits, we're going mapping!*

If you've been reading diligently thusfar, you probably caught the short definition in the [Vocab Lesson](#vocab-lesson).  We're going to expand on that a fair bit more though!

### A Little Background

*Back in the glory days of Yosemite, we were spoiled.  Hackintoshes roamed free in the tech fields, grazing lazily on the abundant USB ports that sprouted from the fertile ground... Then El Capitan showed up - touting that mouse cursor trick where it gets bigger when you wiggle it around a bunch (and uh.. probably other useful features), and we Hack Ranchers gathered up our livestock and trotted wide-eyed to its enticingly greener pastures - little did we know, though, that Apple snuck something in the code that would prove to be a thorn in our sides for OS versions to come...*

There were some *major* under-the-hood changes regarding USB from 10.10 to 10.11...

#### The... *shudder* - Port Limit:

*You finally got your install USB created, sweat pouring down your forehead as you plug that small instrument of black magic into a USB port and shakily press the power button.  The machine springs to life, fans whirring and circulating - lights all aglow.  Your display blinks, opens its metaphorical eyes and the BIOS splash screen greets you in its "I'm an 80s dream of the future" aesthetic - followed shortly by the boot picker for your boot manager of choice.  The selector moves to your install USB and you methodically press the Enter key.  Verbose text races across the screen, line by meticulous line, giving you a peek behind the curtain and into the heart of the boot process... but.. something's not right.  The text garbles... a large "prohibited" sign affixes itself squarely to the center of your display and seemingly taunts you as booting halts save for one slowly repeating line of garbled text.  Your eyes squint as you trace them over the mostly broken text... "Still waiting for root device..."*

*Wait... what just happened?*

One of the biggest changes to affect us Hackintoshers is that Apple now imposes a 15 USB port per controller limit.  At the surface, this doesn't sound terribly problematic.  Most motherboards have far fewer than 15 physical ports - not to mention some have third party chipsets that can share the load (since *each* controller has its own 15 port limit).

So... *what's the catch?*

I'm glad you asked!  Most modern motherboard USB controllers leverage the XHCI protocol to handle all their USB ports, and USB 3 is a bit *sneaky*.  When EHCI (USB 2) came about, it was really just an expansion upon the existing UHCI/OHCI (USB 1) protocol, so backward compatibility using the same physical port layout was pretty easy to ensure.

Let's have a look at the inside of a USB 3 port (image courtesy of usb.com):

~~Will add an image here after the initial writeup~~

