# Overview
This display driver for LCDSmartie allows control for Soundgraph's iMON 2x16 VFD display module
that was being produced around 2008-2010.  The primary target for this driver is the VFD used in
the Chieftec HM-01, HM-02, and HM-03 home theater PC cases, but it may be compatible with other
products from that time frame that also used iMON VFD modules.

# Required Software
As opposed to the earlier iMON VFD modules, which connect to the PC using the parallel port and
communicate with it using the SG_VFD.DLL driver, the module targeted here is USB-based and
contains additional functionality, such as knobs and buttons, in addition to the VFD display.
The driver required for this module is iMONDisplay.DLL, and it can be found as part of the API
zip file, iMON_Display_API_1_00_0929.zip, released by Soundgraph in 2010.  I am including the zip
file here for convenience.

# How to Use
The imon_2010_vfd.dll file should be copied to the "displays" sub-folder of LCDSmartie.  The
iMONDisplay.dll file can exist in any folder, but it is probably most convenient to copy it to
the same folder as the LCDSmartie.exe executable.

If iMONDisplay.dll is in the same folder as LCDSmartie.exe, then there is no further configuration
required.  Simply choose the imon_2010_vfd.dll driver in the LCDSmartie GUI, and set the display
size to 2x16.  However, if iMONDisplay.dll is in a different folder, then the folder for that DLL
needs to be entered in the "Startup Parameters" field in the GUI.
