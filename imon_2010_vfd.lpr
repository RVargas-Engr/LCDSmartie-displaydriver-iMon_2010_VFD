// imon_2010_vfd.lpr
// Display driver for LCDSmartie for the newer versions of Soundgraph's
// iMON VFD that use the API released by Soundgraph in 2010.  The DLL
// required for interfacing to the hardware is iMONDispay.DLL rather
// than the older SG_VFD.DLL.
//
// Copyright (C) 2026  Roy Vargas
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

// This project resides on GitHub at
// github.com/RVargas-Engr/LCDSmartie-displaydriver-iMon_2010_VFD

library imon_2010_vfd;

{$MODE Delphi}

{.$R *.res}

uses
  Windows,SysUtils,Math,Process;

const
  DLLProjectName = 'iMON 2010 VFD Display Driver';
  Version = 'v1.0';
  Soundgraph_Window = 'SG_DISPLAY_PLUGIN_MSG_WND';
  imon_hw_driver = 'iMONDisplay.dll';
  this_project = 'imon_2010_vfd';
type
  pboolean = ^boolean;

var
  FrameBuffer        : array[1..2] of array[1..20] of ushort;
  IMONDLL           : HMODULE = 0;
  MyX,MyY           : byte;
  plugin_msg_rcvd   : boolean;
  plugin_msg_wparam : WPARAM;
  plugin_msg_lparam : LPARAM;
  result_str        : AnsiString;
  inside_already    : Boolean = false;
  func_entry_count  : integer = 0;
  retry_sleep_time_ms : integer = 100; // 100ms per failed connection attempt
  max_retries       : integer = 50;    // try up to 50 times to connect successfully
  wc_atom           : ATOM = 0;
  hWindow           : HWND = 0;        // handle to our transient window
  ourmessage        : UINT = WM_APP + 1001;
  comm_timeout      : integer = 3200; // 3200ms allowed to wait for messages
{$IFDEF DEBUG}
  debug_mode        : Boolean = True;
{$ELSE}
  debug_mode        : Boolean = False;
{$ENDIF}


type
  TDSPResult = ( DSP_SUCCEEDED = 0,
                DSP_E_FAIL,
                DSP_E_OUTOFMEMORY,
                DSP_E_INVALIDARG,
                DSP_E_NOT_INITED,
                DSP_E_POINTER,
                DSP_S_INITIED = $1000,
                DSP_S_NOT_INITED,
                DSP_S_IN_PLUGIN_MODE,
                DSP_S_NOT_IN_PLUGIN_MODE );
  TDSPNInitResult = ( DSPN_SUCCEEDED = 0,
                      DSPN_ERR_IN_USING = $100,
                      DSPN_ERR_HW_DISCONNECTED,
                      DSPN_ERR_NOT_SUPPORTED_HW,
                      DSPN_ERR_PLUGIN_DISABLED,
                      DSPN_ERR_IMON_NO_REPLY,
                      DSPN_ERR_UNKNOWN = $200 );
  TDSPNotifyCode = ( DSPNM_PLUGIN_SUCCEED = 0,
                     DSPNM_PLUGIN_FAILED,   // 1
                     DSPNM_IMON_RESTARTED,  // 2
                     DSPNM_IMON_CLOSED,     // 3
                     DSPNM_HW_CONNECTED,    // 4
                     DSPNM_HW_DISCONNECTED, // 5
                     DSPNM_LCD_TEXT_SCROLL_DONE = $1000 );
  TiMONInitFunc =     function(hwnd : HWND; msg : UINT) : TDSPResult; cdecl;
  TiMONUninitFunc =   function : TDSPResult; cdecl;
  TiMONIsInitedFunc = function : TDSPResult; cdecl;
  TiMONIsPluginModeEnabledFunc = function : TDSPResult; cdecl;
  TiMONSetTextFunc =  function(szFirstLine,szSecondLine : pchar) : integer; cdecl;
  //TiMONSetEQFunc =    function(arEQValue : pinteger) : integer; cdecl;

var
  iMONInitFunc     : TiMONInitFunc = nil;
  iMONUninitFunc   : TiMONUninitFunc = nil;
  iMONIsInitedFunc : TiMONIsInitedFunc = nil;
  iMONIsPluginModeEnabledFunc : TiMONIsPluginModeEnabledFunc = nil;
  iMONSetTextFunc  : TiMONSetTextFunc = nil;
  //iMONSetEQFunc    : TiMONSetEQFunc = nil;

/////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////

//  Define any required forward references.
procedure roll_back_init(error_msg_to_log : PChar); forward;


//  Name: log_to_file
//
//  Description:
//        This function will write the passed-in string to the driver's
//        log file located in the same directory as the LCDSmartie.exe
//        executable.
//
function log_to_file(p : PChar) : Boolean;
var
  f : TextFile;
begin
  AssignFile(f, 'imon_2010_vfd.log');
  {$I+}
  try
    Append(f);
    WriteLn(f, p);
    CloseFile(f);
    result := true;
  except
    on E: EInOutError do begin
      // The file probably does not exist, so use ReWrite() to create it from
      // scratch.
      try
        ReWrite(f);
        WriteLn(f,p);
        CloseFile(f);
        result := true;
      except
        on E: EInOutError do begin
          result := false;
        end;
      end;
    end;
    on E: Exception do
      // The file probably does not exist, so use ReWrite() to create it from
      // scratch.
      try
        ReWrite(f);
        WriteLn(f,p);
        CloseFile(f);
        result := true;
      except
        on E: EInOutError do begin
          result := false;
        end;
      end;
  end;
end;


//  Name: InitWndProc
//
//  Description:
//        This is the Windows WndProc used during initialization of the 
//        connection between the LCDSmartie driver and Soundgraph's iMON
//        display driver.  The 2010 API for the iMON requires this type
//        of connection in order to unlock access to the display.  Once
//        the connection is made, this WndProc is no longer needed.
//
function InitWndProc(Wnd: HWND; Msg: UINT; wParam: WPARAM; lParam: LPARAM) : LRESULT; stdcall;
var
  temp_str : String;
begin
  if debug_mode then begin
    temp_str := FormatDateTime('yyyy-mm-dd hh:mm:ss.zzz', Now()) +
                ': Inside InitWndProc:                ' +
                ' Win:' + Format('%8u', [Wnd]) +
                ' Msg:' + Format('%5u', [Msg]) +
                ' wP:' + Format('%10u', [wParam]) +
                ' lP:' + Format('%6u', [lParam]);
    log_to_file(PChar(temp_str));
  end;

  if (Msg = ourmessage) then begin
    // This is the notification message we need to detect in order to confirm
    // that the iMON display is ready to communicate with us.
    // Expected values for wParam are (from the iMON spec):
    //
    // wParam value    Token                    lParam
    //      0        DSPNM_PLUGIN_SUCCEED
    //      1        DSPNM_PLUGIN_FAILED
    //                                         257 = DSPN_ERR_HW_DISCONNECTED (every 3 seconds)
    //                                         260 = DSPN_ERR_IMON_NO_REPLY
    //      2        DSPNM_IMON_RESTARTED
    //      3        DSPNM_IMON_CLOSED
    //      4        DSPNM_HW_CONNECTED
    //      5        DSPNM_HW_DISCONNECTED
    //    $1000      DSPNM_LCD_TEXT_SCROLL_DONE (LCD only)
    //
    plugin_msg_rcvd := true;
    plugin_msg_wparam := wParam;
    plugin_msg_lparam := lParam;
    result := 0;

    if debug_mode then begin
      // Log this received message in a more human readable format.
      if TDSPNotifyCode(plugin_msg_wparam) = DSPNM_HW_CONNECTED then begin    // DSPNM_HW_CONNECTED
        log_to_file(PChar(Format('%80s',['']) + 'DSPNM_HARDWARE_CONNECTED :'));
        // Observation: wParam=4 and lParam=131073 (0x2 0001) where LSB=1 means VFD hardware
      end else if TDSPNotifyCode(plugin_msg_wparam) = DSPNM_IMON_RESTARTED then begin
        log_to_file(PChar(Format('%80s',['']) + 'DSPNM_IMON_RESTARTED'));
        // Observation: wParam=2 and lParam=65537 (0x1 0001) where LSB=1 means VFD hardware
      end else if TDSPNotifyCode(plugin_msg_wparam) = DSPNM_PLUGIN_FAILED then begin
        if TDSPNInitResult(lParam) = DSPN_ERR_HW_DISCONNECTED then begin
          log_to_file(PChar(Format('%80s',['']) +
                            'DSPNM_PLUGIN_FAILED : DSPN_ERR_HW_DISCONNECTED'));
        end else if TDSPNInitResult(lParam) = DSPN_ERR_IMON_NO_REPLY then begin
          log_to_file(PChar(Format('%80s',['']) +
                            'DSPNM_PLUGIN_FAILED : DSPN_ERR_IMON_NO_REPLY'));
        end else begin
          log_to_file(PChar(Format('%80s',['']) +
                            'DSPNM_PLUGIN_FAILED : (other)'));
        end;
      end else if TDSPNotifyCode(plugin_msg_wparam) = DSPNM_PLUGIN_SUCCEED then begin
        log_to_file(PChar(Format('%80s',['']) + 'DSPNM_PLUGIN_SUCCEED'));
      end;
    end;

  end else if Msg = 537 then begin
    // Msg=537  WM_DEVICECHANGE
    if debug_mode then begin
      log_to_file(PChar('We received a WM_DEVICECHANGE message.'));
      if wParam = 7 then
        log_to_file(PChar('FYI: wParam=7 means DBT_DEVNODES_CHANGED.'));
    end;
    result := 0;
  end else if Msg = 799 then begin
    // Msg=799  WM_DWMNCRENDERINGCHANGED
    if debug_mode then begin
      log_to_file('We received a WM_DWMNCRENDERINGCHANGED message (code=799).');
      log_to_file('FYI: It specifies that DWM rendering is enabled for the non-client area of the window.');
    end;

    result := 0;

  // Other messages that Windows typically sends us during initialization are
  // listed below.  These are just passed to DefWindowProc for processing.
  // Msg=36    WM_GETMINMAXINFO
  // Msg=129   WM_NCCREATE
  // Msg=131   WM_NCCALCSIZE
  // Msg=1     WM_CREATE
  // Msg=144   WM_UAHDESTROYWINDOW
  // Msg=2     WM_DESTROY
  // Msg=130   WM_NCDESTROY
  //
  // Messages received during operation:
  // Msg=28    WM_ACTIVATEAPP - when I click the "Hide" button in the LCD Smartie
  //                             window, we get this first with wParam=1 and then
  //                             immeditately after with wParam=0.
  // Msg=537,wParam=7  WM_DEVICECHANGE::DBT_DEVNODES_CHANGED.
  // Msg=26    WM_WININICHANGE
  // Msg=536
  // Msg=49982,0,0 (perhaps from iMON?)
  // Msg=800
  // Msg=49825,0,0 (perhaps from iMON?)
  // Msg=30    WM_TIMECHANGE
  // Msg=50146,0,0 (perhaps from iMON?)
  //
  // Messages received after destroying the window include:
  // Msg=28    WM_ACTIVATEAPP, both wParam=1 (being activated) and wParam=0 (losing activated state)
  // Msg=537   (WM_DEVICECHANGE, see above)
  // Msg=49868,wParam=4354,lParam=10945898 (from iMon? 3.5sec after destroying, see below)
  // Msg=49869,wParam=4354,lParam=10945898 (from iMon? 3.5sec after destroying, see below)
  //
  // Other messages that we, or the SoundGraph driver, might receive are listed below.
  // The ones going to us just get passed to DefWindowProc for processing.
  // Note: When PC is already running, expect to see only messages 1, 2, and 4.
  // Other messages below seem to show up only during wake-from-standby.
  //    hWnd      Mesage ID  wParam     lParam
  // ----------------------------------------------------------------
  // 1) US          49868     4096   hWnd of SG_DISPLAY_PLUGIN_MSG_WND
  // 2) SoundGraph  49868     4096   hWnd of SG_DISPLAY_PLUGIN_MSG_WND
  // 3) SoundGraph  49868     4128       257        seems to happen right before we receive
  //                                                 a WM_APP+1001,1,257 (DSPN_ERR_HW_DISCONNECTED)
  //    US          49868     4354     10945898
  //    SoundGraph  49868     4354     10945898     same as above
  //    US          49869     4354     10945898
  //    SoundGraph  49869     4354     10945898     same as above
  // 4) SoundGraph  49868     4112     10945898     seems to come before we receive
  //                                                 a WM_APP+1001,0,1 (success); but there may
  //                                                 also be 4114 and 4116 in between
  //    SoundGraph  49868     4114     10945898
  //    SoundGraph  49868     4116        1
  //
  // Note: I alternately see MsgID=49726 and 49727 rather than 49868/49869

  end else begin
    // Any other message we receive must be processed normally by Windows
    // by calling DefWindowProc().
    result := DefWindowProc(Wnd, Msg, wParam, lParam);
  end;
end;


//  Name: process_plugin_msg
//
//  Description:
//        This function is called after the driver's InitWndProc function has
//        detected that a message has been received from the Soundgraph driver.
//
function process_plugin_msg(var sg_window : HWND;
                            var init_try_counter : Integer;
                            var error_str : String) : Integer;
var
  temp_str     : String;
  rc           : DWORD;
  msg          : TMsg;
  dspresult    : TDSPResult;
  kill_proc    : TProcess;
  imon_proc    : TProcess;
begin
  result := 0;

  // See if the message indicates a success (wparam = 0, 2, or 4) or a
  // failure (wparam <> 0, 2, or 4).
  if TDSPNotifyCode(plugin_msg_wparam) = DSPNM_PLUGIN_SUCCEED then begin // wparam=0
    // We received a success message from the plug-in.  The lparam contains
    // whether the display hardware is a VFD (1) or a LCD (2).  Since this
    // display driver only contains functions for the VFD, we will abort
    // the initialization if an LCD is detected instead of a VFD.
    if (plugin_msg_lparam and $01) <> $01 then begin
      // The display hardware is not a VFD, so abort the initialization.
      // Destroy the transient window and unregister the window class.
      // Roll back all progress and exit.
      error_str := 'Connected hardware is not a VFD!';
      roll_back_init(PChar(error_str));
      exit(-1);
    end else
      // successful connection to Soundgraph API.
      result := 1;
  end else if (TDSPNotifyCode(plugin_msg_wparam) = DSPNM_HW_CONNECTED) or
              (TDSPNotifyCode(plugin_msg_wparam) = DSPNM_IMON_RESTARTED) then begin
    // wParam = 2 is DSPNM_HW_RESTARTED. This is another success value.
    // wParam = 4 is DSPNM_HW_CONNECTED. This is another success value.
    // FYI: A DSPNM_HW_RESTARTED message will be received if the iMon
    // Manager software is killed and then re-launched.
    // lParam will have bit D0 high if it's a VFD and
    //                  bit D1 high if it's a LCD.
    if debug_mode then
      log_to_file(PChar('Received alternate success message wParam='
                        + IntToStr(plugin_msg_wparam) + ' from iMON.'));

    if (plugin_msg_lparam and $01) <> $01 then begin
      // The display hardware is not a VFD, so abort the initialization.
      // Destroy the transient window and unregister the window class.
      // Roll back all progress and exit.
      error_str := 'Connected hardware is not a VFD!';
      roll_back_init(PChar(error_str));
      exit(-1);
    end else
      // successful connection to Soundgraph API.
      result := 1;
  end else begin
    // We received an error message from the plug-in.  The lparam contains
    // more details:
    //   $100       = DSPN_ERR_IN_USED
    //   $101 (257) = DSPN_ERR_HW_DISCONNECTED
    //   $102       = DSPN_ERR_NO_SUPPORTED_HW
    //   $103       = DSPN_ERR_PLUGIN_DISABLED
    //   $104 (260) = DSPN_ERR_IMON_NO_REPLY
    //   $200       = DSPN_ERR_UNKNOWN
    //
    // For now, the code does not do anything specific with the type of
    // error.
    if debug_mode then
      log_to_file(PChar(FormatDateTime('yyyy-mm-dd hh:mm:ss.zzz', Now()) +
                        ': Message received from iMON API plug-in:' +
                        ' wParam=' + IntToStr(plugin_msg_wparam) + ' (failure) ' +
                        ' lParam=' + IntToStr(plugin_msg_lparam)));

    // Set up a quick loop to process all messages that may have piled up
    // in the queue, regardless of what window they belong to.
    // NOTE: THERE IS A POSSIBILITY THAT WE RECEIVE MORE MESSAGES FOR
    // EITHER OUR TRANSIENT WINDOW OR FOR THE SOUNDGRAPH WINDOW IN THE
    // FOLLOWING LOOP.  HOWEVER, SINCE WE ARE COMMITTED TO RE-INITIALIZING
    // THE CONNECTION, WE WILL NOT DO ANY SPECIAL PROCESSING OF THOSE
    // MESSAGES.
    rc := MsgWaitForMultipleObjects(0, nil, false, 1000, QS_ALLINPUT);
    if rc = WAIT_OBJECT_0 then begin
      while PeekMessage(@msg, 0, 0, 0, 0) do begin
        GetMessage(@msg, 0, 0, 0);
        
        if debug_mode then begin
          // Log any message targeting our window or the Soundgraph window.
          if (msg.hwnd = sg_window) or (msg.hwnd = hWindow) then begin
            // This message is going to either our own transient window or to
            // the Soundgraph plugin window.  In either case, let's log this.
            if msg.hwnd = sg_window then begin
              temp_str := 'Soundgraph';
            end else begin
              temp_str := 'our window';
            end;
            temp_str := FormatDateTime('yyyy-mm-dd hh:mm:ss.zzz', Now()) +
                        ': Prior to Re-Init, dispatching message for' +
                        temp_str + ':' +
                        ' Win:' + Format('%8u', [msg.hwnd]) +
                        ' Msg:' + Format('%5u', [msg.message]) +
                        ' wP:' + Format('%10u', [msg.wParam]) +
                        ' lP:' + Format('%6u', [msg.lParam]);
            log_to_file(PChar(temp_str));
          end;
        end;

        TranslateMessage(@msg);
        DispatchMessage(@msg);
      end;
    end;

    // NOTE: IT IS POSSIBLE (ALTHOUGH NOT COMMON) FOR US TO RECEIVE A
    // DSPNM_HW_CONNECTED (wParam=4) IN THE INNER WHILE LOOP ABOVE AFTER
    // HAVING FIRST RECEIVED A DSPNM_PLUGIN_FAILED::DSPN_ERR_HW_DISCONNECTED.
    // IT APPEARS TO BE OK, IN SUCH A CASE, FOR US TO CONTINUE TO PROCESS
    // THE HW_DISCONNECTED ERROR AS USUAL, AND THE CONNECTION WILL BE MADE
    // RIGHT AWAY.

    // Let's try up to 5 times in a 1 second timeframe to get a
    // successful connection by calling iMONInitFunc() again.
    if debug_mode then
      log_to_file(PChar(FormatDateTime('yyyy-mm-dd hh:mm:ss.zzz', Now())
                        + ': Preparing to call iMONInitFunc a 2nd time.'));

    //--------------------------------
    // NOTE: IT DOES NOT APPEAR TO BE NECESSARY TO UNINIT THE IMON API HERE,
    // BUT I AM GOING TO TRY IT ANYWAY SINCE I HAVE OBSERVED THAT THE IMON
    // SOFTWARE CHANGES ITS HWND EVERY TIME I CALL iMONInitFunc(), AND I
    // WANT TO BE SURE IT HAS CLOSED ITS OLD HWND.
    //--------------------------------
    dspresult := iMONUninitFunc();
    if debug_mode then
      if dspresult <> DSP_SUCCEEDED then begin
        log_to_file(PChar('Call to iMONUninitFunc() failed, before 2nd call to iMONInitFunc(): ' +
                    IntToStr(QWord(dspresult))));
      end;

    if TDSPNInitResult(plugin_msg_lparam) = DSPN_ERR_IMON_NO_REPLY then begin
      // This is the DSPN_ERR_IMON_NO_REPLY error, which is returned when the
      // iMon Manager program is unresponsive.  To get the VFD working again,
      // we will need to kill the unresponsive process and then re-launch iMON
      // Manager.

      if debug_mode then
        log_to_file('Killing and Re-launching iMON Manager.');

      // Let's try to kill the process and re-launch it.
      kill_proc := TProcess.Create(nil);
      kill_proc.Executable := 'C:\Windows\System32\taskkill.exe';
      kill_proc.Parameters.Add('/f');
      kill_proc.Parameters.Add('/im');
      kill_proc.Parameters.Add('iMON.exe');
      kill_proc.Options := kill_proc.Options + [poWaitOnExit];
      kill_proc.Execute;
      kill_proc.Free;

      if debug_mode then
        log_to_file('Unresponsive iMON Manager process has been killed.');

      imon_proc := TProcess.Create(nil);
      imon_proc.Executable := 'C:\Program Files (x86)\SoundGraph\iMON\iMON.exe';
      imon_proc.Execute;
      imon_proc.Free;

      if debug_mode then
        log_to_file('New iMON Manager process has been started.');
    end;

    dspresult := iMONInitFunc(hWindow, ourmessage);
    if dspresult = DSP_E_INVALIDARG then begin
      // Error 3 means DSP_E_INVALIDARG, but we know that our window handle
      // and message ID are valid.  Since I'm only seeing this error after
      // a wake-from-standby, let's just wait and see if the iMON API might
      // just need a little more time to get things straightened out on its
      // end.
      if debug_mode then begin
        log_to_file('DSP_E_INVALIDARG received when calling iMONInitFunc() with these arguments:');
        log_to_file(PChar('hWnd=' + IntToStr(hWindow) + ', message=' + IntToStr(ourmessage)));
      end;
    end else if (dspresult <> DSP_SUCCEEDED) then begin
      error_str := 'iMONInitFunc returned error code ' +
                    IntToStr(QWord(dspresult)) +
                    ' after iMON plug-in error.' + #0;
      roll_back_init(PChar(error_str));
      exit(-1);
    end;

    // The Soundgraph API may set up a new message window each time we call
    // iMONINitFunc(), so let's find it again.
    sg_window := FindWindow(Soundgraph_Window, nil);
    if sg_window = 0 then begin
      error_str := 'Could not get window handle for Soundgraph message window.';
      roll_back_init(PChar(error_str));
      exit(-1);
    end;

    // Set plugin_msg_rcvd to false so that the outer loop iterates one
    // more time.
    plugin_msg_rcvd := false;
    init_try_counter := init_try_counter - 1;

    // Wait some amount of time before trying again (around 100ms is good).
    if debug_mode then
      log_to_file(PChar('Sleep for ' + IntToStr(retry_sleep_time_ms) + ' ms before retrying.'));
    
    sleep(retry_sleep_time_ms);
  end;
end;


//  Name: roll_back_init
//
//  Description:
//        This function is called when an error occurs while setting up
//        the communication to the Soundgraph driver.
//
procedure roll_back_init(error_msg_to_log : PChar);
var
  func_status : Boolean;
  last_error  : DWORD;
begin
  if debug_mode then
    log_to_file('Begin roll_back_init.');
  
  inside_already := false;
  
  // Uninitialize the iMON API.
  iMONUninitFunc;
  if debug_mode then
    log_to_file('iMON API has been un-initialized.');

  // Try sleeping for 1 second before we destroy the transient window just to
  // see if the iMON API sends us any messages after we uninitialize it.
  sleep(1000);

  // Destroy our transient window, if it exists.
  if hWindow <> 0 then begin
    DestroyWindow(hWindow);
    hWindow := 0;

    if debug_mode then
      log_to_file('Transient window has been destroyed.');
  end;

  // Unregister the Windows class related to our transient window,
  // if it exists.
  if wc_atom <> 0 then begin
    func_status := Windows.UnregisterClass(LPCTSTR(wc_atom), 0);
    if func_status = false then begin
      last_error := Windows.GetLastError();
      log_to_file(PChar('Unregister Class failed with code ' +
                        IntToStr(last_error)));
    end else begin
      if debug_mode then
        log_to_file('Window class has been unregistered.');
    end;
  end;

  // Here, the source of the error gets logged whether we're in 
  // debug_mode or not.
  log_to_file(error_msg_to_log);

  if debug_mode then begin
    log_to_file('Exit roll_back_init.');
  end;
end;


//  Name: DISPLAYDLL_Init
//
//  Description:
//        This function is called by LCDSmartie to initialize the display
//        upon startup or wake from standby.
//
function DISPLAYDLL_Init(SizeX,SizeY : byte; StartupParameters : pchar; OK : pboolean) : pchar; stdcall;
// return startup error
// open port
var
  Path             : string;
  WindowClass      : WndClass;
  sg_window        : HWND;
  msg              : TMsg;
  dspresult        : TDSPResult;
  rc               : DWORD;
  last_error       : DWORD;
  my_peek_status   : Boolean;
  sg_peek_status   : Boolean;
  func_status_int  : Integer;
  runaway_counter  : integer;
  init_try_counter : integer;
  temp_str         : String;
  plugin_success   : Boolean;
begin
  if debug_mode then
    log_to_file(PChar(FormatDateTime('yyyy-mm-dd hh:mm:ss.zzz', Now()) +
                      ': Begin DISPLAYDLL_Init.'));

  func_entry_count := func_entry_count + 1;
  if inside_already = true then begin
    OK^ := true; // A return of "false" causes a popup, so don't do that.
    result := PChar('Recursive call into the function!' + #0);
    if debug_mode then
      log_to_file(PChar('Exit DISPLAYDLL_Init: Recursive call into the function'));
    exit(result);
  end;

  OK^ := true;
  result_str := DLLProjectName + ' ' + Version + #0;
  result := PChar(result_str);
  fillchar(FrameBuffer,sizeof(FrameBuffer),$00);
  MyX := 1;
  MyY := 1;

  hWindow := 0;
  wc_atom := 0;

  if debug_mode then
    log_to_file('Continue Init function.');

  try
    Path := trim(string(StartupParameters));
    if (length(Path) > 0) then begin
      Path := includetrailingpathdelimiter(Path);
    end;
    temp_str := PChar(Path + imon_hw_driver);
    IMONDLL := LoadLibrary(PChar(temp_str));
    if (IMONDLL = 0) then begin
      result_str := this_project + '.dll Exception: <' + temp_str + '> not found!' + #0;
      result := PChar(result_str);
      OK^ := false;
      log_to_file(PChar('Exit DISPLAY_DLL_Init: Could not load DLL <' + temp_str + '>.'));
      exit(result);
    end;

    iMONInitFunc     := getprocaddress(IMONDLL,pchar('IMON_Display_Init' + #0));
    iMONUninitFunc   := getprocaddress(IMONDLL,pchar('IMON_Display_Uninit' + #0));
    iMONIsInitedFunc := getprocaddress(IMONDLL,pchar('IMON_Display_IsInited' + #0));
    iMONIsPluginModeEnabledFunc := getprocaddress(IMONDLL,pchar('IMON_Display_IsPluginModeEnabled' + #0));
    iMONSetTextFunc  := getprocaddress(IMONDLL,pchar('IMON_Display_SetVfdText' + #0));
    // IMON_Display_SetVfdEqData is available as a function for the VFD, but
    // this driver does not make use of that functionality.
    //iMONSetEQFunc    := getprocaddress(IMONDLL,pchar('IMON_Display_SetVfdEqData' + #0));

    if not assigned(iMonIsInitedFunc) then begin
      OK^ := false;
      result := PChar('iMonIsInitedFunc undefined.' + #0);
      log_to_file(result);
      exit(result);
    end;
    if not assigned(iMonIsPluginModeEnabledFunc) then begin
      OK^ := false;
      result := PChar('iMonIsPluginModeEnabledFunc undefined.' + #0);
      log_to_file(result);
      exit(result);
    end;
    if not assigned(iMonInitFunc) then begin
      OK^ := false;
      result := PChar('iMonInitFunc undefined.' + #0);
      log_to_file(result);
      exit(result);
    end;
    if not assigned(iMONUninitFunc) then begin
      OK^ := false;
      result := PChar('iMONUninitFunc undefined.' + #0);
      log_to_file(result);
      exit(result);
    end;

    // Un-initialize the display to get it to a known state, even if it was
    // already un-initialized.
    dspresult := iMONUninitFunc;
    //  Un-initialization must be successful in order for us to continue.
    if (dspresult <> DSP_SUCCEEDED) then begin
      result_str := 'iMONUninitFunc failed: error code ' +
                    IntToStr(QWord(dspresult)) + #0;
      result := PChar(result_str);
      OK^ := false;
      log_to_file(result);
      exit(result);
    end;

    // Double-check that "IsInited" returns 4097 (DSP_S_NOT_INITED).
    dspresult := iMONIsInitedFunc;
    if (dspresult <> DSP_S_NOT_INITED) then begin
      result_str := 'iMONIsInitedFunc returned ' + IntToStr(QWord(dspresult)) +
                    ' but expected 4097.' + #0;
      result := PChar(result_str);
      OK^ := false;
      log_to_file(result);
      exit(result);
    end;

    // Triple-check that "PluginModeEnabled" returns 4 (DSP_E_NOT_INITED).
    dspresult := iMONIsPluginModeEnabledFunc;
    if (dspresult <> DSP_E_NOT_INITED) then begin
      result_str := 'IsPluginModeEnabledFunc returned ' + IntToStr(QWord(dspresult)) +
                    ' but expected 4.' + #0;
      result := PChar(result_str);
      OK^ := false;
      log_to_file(result);
      exit(result);
    end;
  except
    on E: Exception do begin
      result_str := this_project + '.dll Exception: ' + E.Message + #0;
      result := PChar(result_str);
      OK^ := false;
      log_to_file(result);
      exit(result);
    end;
  end;

  if debug_mode then
    log_to_file('iMON has been verified to be un-initialized.');

  // INITIALIZATION - PHASE 2:
  // Proceed with the rest of the initialization only if the preceding
  // code was successful.
  // The way the new iMON API works is that we have to provide a Window
  // handle to it, which it will use to Post a status message.  We don't
  // really do anything with the message, but the Window handle must be a
  // valid one, so we'll create a transient window here.  This window
  // will get destroyed in the DISPLAYDLL_Done function.
  WindowClass.lpszClassName := this_project;
  WindowClass.Style := cs_hRedraw or cs_vRedraw;
  WindowClass.hbrBackground := GetStockObject(WHITE_BRUSH);
  WindowClass.lpfnWndProc := @InitWndProc;
  WindowClass.hInstance := 0;
  WindowClass.cbClsExtra := 0;
  WindowClass.cbWndExtra := 0;
  WindowClass.hIcon := LoadIcon(0, idi_Application);
  WindowClass.hCursor := LoadCursor(0, idc_Arrow);
  WindowClass.lpszMenuName := nil;

  // Register the window class with Windows.
  wc_atom := Windows.RegisterClass(@WindowClass);
  if (wc_atom = 0) then begin
    // Registration failed.
    OK^ := false;

    last_error := Windows.GetLastError();

    temp_str := 'Attempt to register the Windows Class has failed: ' + IntToStr(last_error);
    log_to_file(PChar(temp_str));

    result_str := 'RegisterClass error ' + IntToStr(last_error) +
                  ' func_entry_count=' + IntToStr(func_entry_count) + #0;
    result := PChar(result_str);
    log_to_file(result);
    exit(result);
  end;

  if debug_mode then
    log_to_file('Window Class has been successfully registered.');

  // Create the transient window.  This exists only to get the VFD Plugin Mode
  // established.  We destroy it later in the DISPLAYDLL_Done function.
  // Note: The driver can continue to send messages, for example, if the
  // iMON Manager is restarted or closed, or if the hardware is connected or
  // disconnected, but there is no mechanism in LCDSmartie to do anything
  // useful with that information.
  hWindow := CreateWindow(WindowClass.lpszClassName,
                          DLLProjectName,
                          ws_Caption, 100, 100, 900, 900,
                          0, 0, 0, nil);
  if (hWindow = 0) then begin
    // Unregister the window class, and return with an error.
    Windows.UnregisterClass(this_project, system.MainInstance);
    OK^ := false;
    result := PChar('Failed to create a transient window.' + #0);
    log_to_file(result);
    exit(result);
  end;

  if debug_mode then
    log_to_file('Transient window has been successfully created.');

  // At this point, we have loaded the DLL, un-initialized the display,
  // registered the window class, and successfully created the window.
  // Next, we call the API's Init function and pass in the window handle.
  dspresult := iMONInitFunc(hWindow, ourmessage);
  if (dspresult <> DSP_SUCCEEDED) then begin
    result_str := 'iMONInitFunc returned error code ' + IntToStr(QWord(dspresult)) + #0;
    result := PChar(result_str);
    OK^ := false;
    // Destroy the transient window and unregister the window class.
    DestroyWindow(hWindow);
    hWindow := 0;
    UnregisterClass(this_project, system.MainInstance);
    log_to_file(result);
    exit(result);
  end;

  // At this point, there should be a Soundgraph message window set up, so get
  // the handle for it.
  sg_window := FindWindow(Soundgraph_Window, nil);
  if sg_window = 0 then begin
    OK^ := false;
    result := PChar('Could not get window handle for Soundgraph message window.');
    // Destroy the transient window and unregister the window class.
    DestroyWindow(hWindow);
    hWindow := 0;
    UnregisterClass(this_project, system.MainInstance);
    log_to_file(result);
    exit(result);
  end;

  if debug_mode then
    log_to_file('Starting the temporary Windows Message loop now.');

  inside_already := true;
  plugin_msg_rcvd := false;
  plugin_success := false;
  runaway_counter := 100;
  // Note: Upon wake-from-standby, I have observed that it takes approximately
  // 3 seconds before successful connection is made.  The following 2 values
  // combine to allow a maximum of 5 seconds, if necessary.
  init_try_counter := max_retries;  // 50*100ms allows 5sec to establish connection.

  // Set up a loop to check the Windows message queue for up to 3200ms to
  // look for the message telling us that the display has been initialized.
  // Note: 3200ms was picked because the iMON API seems to have a timeout of around
  // 3 seconds for its connection to iMon Manager before it sends us a timeout
  // error.
  while (plugin_success = false) and
        (runaway_counter > 0) and (init_try_counter > 0) do begin
    rc := MsgWaitForMultipleObjects(0, nil, false, comm_timeout,
              $0100 or QS_SENDMESSAGE or QS_TIMER);

    if debug_mode then begin
      temp_str := 'Back from MsgWaitForMultipleObjects: return value is ' + IntToStr(rc);
      log_to_file(PChar(temp_str));
    end;

    if rc = WAIT_OBJECT_0 then begin
      if debug_mode then
        log_to_file('A message is waiting in the queue.');

      // One or more Windows messages of the specific types is waiting, so use
      // PeekMessage to process only the 2 windows handles that we care about.
      my_peek_status := Windows.PeekMessage(@msg, hWindow, WM_USER, $FFFF, 0);
      sg_peek_status := Windows.PeekMessage(@msg, sg_window, WM_USER, $FFFF, 0);

      if (my_peek_status = false) and (sg_peek_status = false) then
        // This condition will only be allowed 100 times before we abort the
        // initialization.
        runaway_counter := runaway_counter - 1;

      // Set up an inner while loop to process any messages that are ready
      // to be processed for either our transient window or for the Soundgraph
      // message window.
      while (my_peek_status = true) or (sg_peek_status = true) do begin
        if my_peek_status = true then begin
          // There is a message for our window ready to process.
          if GetMessage(@msg, hWindow, WM_USER, $FFFF) = false then begin
            // The only time GetMessage returns "false" is when the message was
            // a WM_QUIT.  I've seen this upon wake from standby, so it appears
            // that LCD Smartie tries to re-initialize upon wakeup.  Unfortunately,
            // it also means that we have crashed LCD Smartie!
            result := PChar('Received an unexpected WM_QUIT message.');
            OK^ := false;
            break;
          end else begin
            // Translate the message and then dispatch it.  This will let Windows
            // call our transient window's WndProc if it's a message for us.  And
            // if it's the "right" message, our WndProc will set plugin_msg_rcvd
            // to "true".
            TranslateMessage(@msg);
            DispatchMessage(@msg);
          end;
        end;

        if sg_peek_status = true then begin
          // There is a message for the Soundgraph message window ready to process.
          GetMessage(@msg, sg_window, WM_USER, $FFFF);

          if debug_mode then begin
            temp_str := FormatDateTime('yyyy-mm-dd hh:mm:ss.zzz', Now()) +
                        ': Dispatching message for Soundgraph:' +
                        ' Win:' + Format('%8u', [msg.hwnd]) +
                        ' Msg:' + Format('%5u', [msg.message]) +
                        ' wP:' + Format('%10u', [msg.wParam]) +
                        ' lP:' + Format('%6u', [msg.lParam]);
            log_to_file(PChar(temp_str));
          end;

          TranslateMessage(@msg);
          DispatchMessage(@msg);
        end;

        // Use PeekMessage again to check for any additional messages for either
        // window.
        my_peek_status := PeekMessage(@msg, hWindow, WM_USER, $FFFF, 0);
        sg_peek_status := PeekMessage(@msg, sg_window, WM_USER, $FFFF, 0);
      end; // end of inner while loop
    end else begin
      if debug_mode then
        log_to_file(PChar(FormatDateTime('yyyy-mm-dd hh:mm:ss.zzz', Now()) +
                          ': No message waiting in the queue.'));
      break;
    end;

    // At this point, see if a message was received from the iMON plug-in.
    if plugin_msg_rcvd = true then begin
      func_status_int := process_plugin_msg(sg_window, init_try_counter, temp_str);
      if func_status_int < 0 then begin
        // error when processing the plugin message, so exit.
        OK^ := false;
        result_str := temp_str;
        exit(PChar(result_str));
      end else if func_status_int > 0 then begin
        plugin_success := true;  // this will terminate the outer while loop
      end;
    end else begin
      // We have not yet received a plugin reply message, and we have already
      // processed any messages for either our window or the Soundgraph message
      // window.  Therefore, we will re-iterate the outer loop to wait again,
      // but before doing so, let's do a quick loop to process all messages
      // that are currently in the queue regardless of what window they belong
      // to.
      // NOTE: IT IS POSSIBLE THAT, IN THE FOLLOWING WHILE LOOP, THERE WILL BE
      // MESSAGES FOR EITHER OUR WINDOW OR THE SOUNDGRAPH WINDOW.  THEREFORE,
      // WE SHOULD PROCESS THOSE AS WE DO ABOVE.  IN FACT, THE ABOVE CODE
      // MAY BECOME OBSOLETE, SUCH THAT WE END UP DOING EVERYTHING BELOW.
      // The only times we will break out of this loop early are:
      // 1) if a successful connection is made.
      // 2) if an error occurs.
      while PeekMessage(@msg, 0, 0, 0, 0) do begin
        GetMessage(@msg, 0, 0, 0);

        if debug_mode then begin
          // Log the message if it's going to our window or Soundgraph's window.
          if (msg.hwnd = sg_window) or (msg.hwnd = hWindow) then begin
            // This message is going to either our own transient window or to
            // the Soundgraph plugin window.  In either case, let's log this.
            if msg.hwnd = sg_window then begin
              temp_str := 'Soundgraph';
            end else begin
              temp_str := 'our window';
            end;
            temp_str := FormatDateTime('yyyy-mm-dd hh:mm:ss.zzz', Now()) +
                        ': Before next iter, dispatching message for ' +
                        temp_str + ':' +
                        ' Win:' + Format('%8u', [msg.hwnd]) +
                        ' Msg:' + Format('%5u', [msg.message]) +
                        ' wP:' + Format('%10u', [msg.wParam]) +
                        ' lP:' + Format('%6u', [msg.lParam]);
            log_to_file(PChar(temp_str));
          end;
        end;
        TranslateMessage(@msg);
        DispatchMessage(@msg);

        // See if a message was received from the iMON plug-in.
        if plugin_msg_rcvd = true then begin
          func_status_int := process_plugin_msg(sg_window, init_try_counter, temp_str);
          if func_status_int < 0 then begin
            // error when processing the plugin message, so exit.
            OK^ := false;
            result_str := temp_str;
            exit(PChar(result_str));
          end else if func_status_int > 0 then begin
            plugin_success := true; // this will terminate the outer while loop

            // Now that a successful connection has been established, stop
            // doing our inner while loop.
            break;
          end;
        end;
      end;
    end;
  end; // end of outer while loop

  if debug_mode then
    log_to_file('Done with the temporary Windows Message loop.');

  // See if we made it through without an error.
  if OK^ = true then begin
    // No errors, so check if the plugin message was received.
    if plugin_msg_rcvd = false then begin
      // Try to find out what happened.
      if rc = WAIT_TIMEOUT then begin
        result := PChar('iMon Manager did not respond within ' + IntToStr(comm_timeout) + 'ms.' + #0);
      end else if rc = WAIT_FAILED then begin
        result := PChar('MsgWaitForMultipleObjects failed.' + #0);
      end else if rc = WAIT_OBJECT_0 then begin
        // Two scenarios can lead us here:
        // 1) Runaway counter reached 0.  We were waiting for a message from the
        //    plugin, and we never got it.  Waiting longer could possibly work,
        //    but the code would ideally have to be modified to process the
        //    messages that are causing the runaway.
        // 2) Init try counter reached 0.  The code received 5 messages from the
        //    plug-in indicating a failure.  At this point, we give up trying.
        if runaway_counter <= 0 then begin
          result := PChar('Message queue runaway counter reached limit.' + #0);
        end else if init_try_counter <= 0 then begin
          result := PChar('Giving up after 5 attempts to connect to display.' + #0);
        end else begin
          result := PChar(' Unexpected failure with WAIT_OBJECT_0 condition.' + #0);
        end;
      end else begin
        result_str := 'MsgWaitForMultipleObject unexpected return ' + IntToStr(rc) + #0;
        result := PChar(result_str);
      end;

      roll_back_init(result);
      OK^ := false;
      exit(result);
    end;

    if debug_mode then
      log_to_file('Approaching the finish line.');
  end else begin
    // We got a WM_QUIT, which was unexpected.
    // Uninitialize the display.
    iMONUninitFunc;
    // Destroy transient window and unregister the class.
    Windows.DestroyWindow(hWindow);
    hWindow := 0;
    Windows.UnregisterClass(this_project, system.MainInstance);
    inside_already := false;
    log_to_file(result);
    exit(result);
  end;

  // Everything went well.
  inside_already := false;
  func_entry_count := 0;

  if debug_mode then begin
    temp_str := FormatDateTime('yyyy-mm-dd hh:mm:ss.zzz', Now()) +
                ': Exit DISPLAYDLL_Init function.  Successful connection made with ' +
                IntToStr(init_try_counter) + ' tries remaining.';
    log_to_file(PChar(temp_str));
  end;
end;


//  Name: DISPLAYDLL_Done
//
//  Description:
//        This function is called by LCDSmartie to shut down the display
//        prior to exiting the program or going into standby.
//
procedure DISPLAYDLL_Done(); stdcall;
var
  last_error   : DWORD;
  func_status  : Boolean;
// close port
begin
  if debug_mode then
    log_to_file(PChar(FormatDateTime('yyyy-mm-dd hh:mm:ss.zzz', Now())
                      + ': Begin DISPLAYDLL_Done().'));
  
  try
    iMONUninitFunc;
    if debug_mode then
      log_to_file('iMONUninitFunc() has been called.');

    sleep(1000);

    if hWindow <> 0 then begin
      // Destroy the transient window now.
      func_status := Windows.DestroyWindow(hWindow);
      if func_status = false then begin
        last_error := Windows.GetLastError();
        log_to_file(PChar('DestroyWindow failed in DISPLAYDLL_Done with code ' +
                          IntToStr(last_error) + ' for window handle ' +
                          IntToStr(hWindow)));

      end else begin
        if debug_mode then
          log_to_file('Transient window has been destroyed.');
      end;
      hWindow := 0;

      // Unregister the window class.
      func_status := Windows.UnregisterClass(LPCTSTR(wc_atom), 0);
      if func_status = false then begin
        last_error := Windows.GetLastError();
        log_to_file(PChar('Unregister Class failed in DISPLAYDLL_Done with code ' +
                          IntToStr(last_error)));
      end else begin
        if debug_mode then
          log_to_file('Window class has been unregistered.');
      end;
    end;

    if not (IMONDLL = 0) then begin
      FreeLibrary(IMONDLL);
      if debug_mode then
        log_to_file(PChar('DLL <' + imon_hw_driver + '> has been freed.'));
    end;
  except
    log_to_file('Exception raised when uninitializing the iMON display.');
  end;

  if debug_mode then
    log_to_file(PChar(FormatDateTime('yyyy-mm-dd hh:mm:ss.zzz', Now())
                      + ': Exit DISPLAYDLL_Done().'));
end;


//  Name: DISPLAYDLL_CustomCharIndex
//
//  Description:
//        This function is called by LCDSmartie to get the character code
//        to use for the given 1-based custom character.  For the iMON VFDs,
//        there are 8 custom characters, and they can be accessed at codes
//        8 through 15.  But LCDSmartie refers to custom characters as 1
//        through 7.  So here, we just add 7 to the passed in value.
//
function DISPLAYDLL_CustomCharIndex(Index : byte) : byte; stdcall;
begin
  DISPLAYDLL_CustomCharIndex := Index + 7; // 8-15
end;


//  Name: DISPLAYDLL_Write
//
//  Description:
//        This function is called by LCDSmartie to write the specified
//        string to the display.
//
procedure DISPLAYDLL_Write(Str : pchar); stdcall;
// write string
var
  S    : string;
  Loop : integer;
  B    : byte;
begin
  S := string(Str);
  for Loop := 1 to min(length(S),20) do begin
    B := ord(S[Loop]);
    // Original code disallowed characters between 0 and 7, between 16 and 31,
    // and at 255 (replaced with a space (' ').  I'm changing this to allow
    // all characters to be written except 0.
    // Code 0 is the first of the custom characters, and it's duplicated at
    // code 8, so the user can access that character by using code 8.
    if (B = 0) then begin
      B := 32; // space character, ' '.
    end;
    // Note: since iMONDisplay.dll requires 16-bit little endian characters,
    // you cannot just do a string copy to FrameBuffer.
    FrameBuffer[MyY][(MyX+Loop)-1] := B;
  end;

  try
    if assigned(iMONSetTextFunc) then
      iMONSetTextFunc(pchar(@FrameBuffer[1]),pchar(@FrameBuffer[2]));
  except
  end;
end;


//  Name: DISPLAYDLL_SetPosition
//
//  Description:
//        This function is called by LCDSmartie to position the display
//        controller's cursor at the specified row and column.  Here,
//        we just set a couple of internal variables that later get used
//        by DISPLAYDLL_Write function.
//
procedure DISPLAYDLL_SetPosition(X, Y: byte); stdcall;
// set cursor position
begin
  MyX := max(min(X,20),1);
  MyY := max(min(Y,2),1);
end;


//  Name: DISPLAYDLL_DefaultParameters
//
//  Description:
//        This function returns a string representing the parameters
//        required to be passed to the Init function in order to set
//        up a "default" configuration.  Here we just return an empty
//        string.
//
function DISPLAYDLL_DefaultParameters : pchar; stdcall;
begin
  DISPLAYDLL_DefaultParameters := pchar(#0);
end;


//  Name: DISPLAYDLL_Usage
//
//  Description:
//        This function is called by LCDSmartie when loading the driver
//        to get a string that it can present to the user to describe
//        what the user should enter in the "Startup Parameters" field
//        for the driver.
//        Here, the only text that this driver needs in that field is
//        the location of the Soundgraph driver.
//
function DISPLAYDLL_Usage : pchar; stdcall;
begin
  Result := pchar('Usage: <dllpath>'+#13#10+
                  'where dllpath is the folder where <' +
                  imon_hw_driver + '> exists.' + #0);
end;


//  Name: DISPLAYDLL_DriverName
//
//  Description:
//        This function returns the name and version number of the
//        driver.
//
function DISPLAYDLL_DriverName : pchar; stdcall;
begin
  Result := PChar(DLLProjectName + ' ' + Version + #0);
end;


// don't forget to export the funtions, else nothing works :)
exports
  DISPLAYDLL_Write,
  DISPLAYDLL_SetPosition,
  DISPLAYDLL_DefaultParameters,
  DISPLAYDLL_CustomCharIndex,
  DISPLAYDLL_Usage,
  DISPLAYDLL_DriverName,
  DISPLAYDLL_Done,
  DISPLAYDLL_Init;

{$R *.res}

begin
end.

