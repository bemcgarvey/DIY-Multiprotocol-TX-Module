---- #########################################################################
---- #                                                                       #
---- # Copyright (C) OpenTX                                                  #
-----#                                                                       #
---- # License GPLv2: http://www.gnu.org/licenses/gpl-2.0.html               #
---- #                                                                       #
---- # This program is free software; you can redistribute it and/or modify  #
---- # it under the terms of the GNU General Public License version 2 as     #
---- # published by the Free Software Foundation.                            #
---- #                                                                       #
---- # This program is distributed in the hope that it will be useful        #
---- # but WITHOUT ANY WARRANTY; without even the implied warranty of        #
---- # MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         #
---- # GNU General Public License for more details.                          #
---- #                                                                       #
---- #########################################################################

------------------------------------------------------------------------------
-- This script library is a rewrite of the original DSM forward programming Lua 
-- Script.  The goal is to make it easier to understand, mantain, and to  
-- separate the GUI from the DSM Forward  programming engine/logic
-- in this way, GUIs can evolve independent. OpenTX Gui, EdgeTx GUI, Small Radios, etc.

-- Code is based on the code/work by: Pascal Langer (Author of the Multi-Module)  
-- Rewrite/Enhancements By: Francisco Arzu 
-- 
------------------------------------------------------------------------------
    --###############################################################################
    -- Multi buffer for DSM description
    -- Multi_Buffer[0..2]=="DSM" -> Lua script is running
    -- Multi_Buffer[3]==0x70+len -> TX to RX data ready to be sent
    -- Multi_Buffer[4..9]=6 bytes of TX to RX data
    -- Multi_Buffer[10..25]=16 bytes of RX to TX data
    --
    -- To start operation:
    --   Write 0x00 at address 3
    --   Write 0x00 at address 10
    --   Write "DSM" at address 0..2
    --###############################################################################


local DEBUG_ON = ... -- Get Debug_ON from parameters.  -- 0=NO DEBUG, 1=HIGH LEVEL 2=MORE DETAILS 

local LIB_VERSION = "0.54"
local LANGUAGE    = "en"

local LOG_FILE = "/LOGS/dsm_log.txt"
local MSG_FILE = "/SCRIPTS/TOOLS/DSMLIB/msg_fwdp_"..LANGUAGE..".txt"


local Lib = { Init_Text = function (rxId) end }

--RX IDs--
local RX = {
    AR636B   = 0x0001,
    SPM4651T = 0x0014,
    AR637T   = 0x0015,
    AR637TA  = 0x0016,
    FC6250HX = 0x0018,
    AR630    = 0x0019,
    AR8360T  = 0x001A,
    AR10360T = 0x001C,
    AR631    = 0x001E
}

local PHASE = {
    RX_VERSION = 0,
    WAIT_CMD = 1,
    MENU_TITLE = 2,
    MENU_REQ_TX_INFO = 3,
    MENU_LINES = 4, MENU_VALUES = 5,
    VALUE_CHANGING = 6, VALUE_CHANGING_WAIT = 7, VALUE_CHANGE_END = 8,
    EXIT = 9, EXIT_DONE = 10
}

local LINE_TYPE = {
    MENU = 0x1C,
    LIST_MENU = 0x0C,  -- List:  TODO: Investigate why the Min/Max on some lines comes with a wide range (0..244) when non-contiguos values. example Valid (3,176,177)
    LIST_MENU_NC = 0x6C,  -- List:  No Incremental Change     
    LIST_MENU_TOG = 0x4C,  -- List:   Seems like a bolean/Toggle menu, just 2 values 0->1  (off/on, ihn/Act)

    VALUE_NUM_I8_NC = 0x60,  --  8 bit number, no incremental change
    VALUE_PERCENT = 0xC0, -- 8 bit number, Signed, percent
    VALUE_DEGREES  = 0xE0, -- 8 bit number, Signed, Degress
    VALUE_NUM_I8 = 0x40, -- 8 bit number
    VALUE_NUM_I16 = 0x41, -- 16 Bit number
    VALUE_NUM_SI16 = 0xC1, -- 16 bit number, Signed  
    LT_EMPTY = 0x00
}

--Channel Types --
local CH_TYPE = {
    NONE     = 0x00,
    AIL      = 0x01,
    ELE      = 0x02,
    RUD      = 0x04,

    REVERSE  = 0x20,
    THR      = 0x40,
    SLAVE    = 0x80,
}

local CH_MIX_TYPE = {
    NORMAL       = 0x00,
    MIX_AIL_B    = 0x10,   -- Traileron B
    MIX_ELE_A    = 0x20,   -- For VTIAL and Delta-ELEVON A
    MIX_ELE_B_REV= 0x30,   -- For VTIAL and Delta-ELEVON B
    MIX_ELE_B    = 0x40,   -- For VTIAL and Delta-ELEVON B
    MIX_ELE_A_REV= 0x50,   -- For VTIAL and Delta-ELEVON A
    MIX_AIL_B_REV= 0x60,   -- Traileron B Rev
    NORM_REV     = 0x70
}

-- Bug in Lua compiler, confusing with global BOLD and RIGHT
local DISP_ATTR = {
    _BOLD = 0x01,  _RIGHT=0x02, _CENTER=0x04, PERCENT = 0x10, DEGREES=0x20, FORCED_MENU = 0x40 
}

local DSM_Context = {
    Phase = PHASE.RX_VERSION,
    Menu = { MenuId = 0, Text = "", TextId = 0, PrevId = 0, NextId = 0, BackId = 0 },
    MenuLines = {},
    RX = { Id=0, Name = "", Version = "" },
    Refresh_Display = true,

    SelLine = 0,        -- Current Selected Line
    EditLine = nil,     -- Current Editing Line 
    CurLine = -1,       -- Current Line Requested/Parsed via h message protocol 
    isReset = false     -- false when starting from scracts, true when starting from Reset
}

-- MODEL information from ETX/OTX
local MODEL = {
    modelName = "",            -- The name of the model comming from OTX/ETX
    modelOutputChannel = {},   -- Output information from OTX/ETX
    
    TX_CH_TEXT = {},
    PORT_TEXT = {},
    DSM_ChannelInfo = {}       -- Data Created by DSM Configuration Script
}


local MAX_MENU_LINES = 6
local BACK_BUTTON    = -1                   -- Tread it as a display line #-1
local NEXT_BUTTON    = MAX_MENU_LINES + 1   -- Tread it as a display line #7
local PREV_BUTTON    = MAX_MENU_LINES + 2   -- Tread it as a display line #7

local SEND_TIMEOUT = 2000 / 10 --  Home many 10ms intervals to wait on sending data to tx to keep connection open   (2s)
local InactivityTime = 0      -- Next time to do heartbeat after inactivity 
local StartTime = 0           -- Start time since the start of the script

local Waiting_RX = 0 -- 1 if Waiting for an RX response, 0 if transmiting
local Value_Change_Step = 0  -- 2 Steps to update. 0=Send update value, 1=Send Verificatin request

local TxInfo_Type = 0
local TxInfo_Step = 0

-- Text Arrays for Display Text and Debuging 
local PhaseText = {}
local LineTypeText = {}

local Text = {}             -- Text for Menu and Menu Lines   (Headers only)
local List_Text = {}        -- Messages for List Options (values only)
local List_Text_Img = {}    -- If the Text has Attached Images
local List_Values = {}      -- Additiona restrictions on List Values when non contiguos  (L_M1 lines has this problem) 
local RxName = {}
local Flight_Mode = {[0]="Flight Mode"}

local logFile  = nil


function DSM_Context.isEditing() return DSM_Context.EditLine~=nil end


---- DSM_ChannelInfo ---------------------------------
-- First byte describe Special  Mixing (Vtail/Elevon = 0x20)
--VTAIL
--(0x00 0x06) CH_TYPE.ELE+CH_TYPE.RUD  (0x02+0x04 = 0x06)
--(0x20 0x86) CH_TYPE.ELE+CH_TYPE.RUD+CH_TYPE.SLAVE  (0x02+0x04+0x80 = 0x86)

-- The 2nd byte describes the functionality of the port 
-- 
-- Single   Example: CH_TYPE.AIL (0x01) Aileron
-- Reverse  Example: CH_TYPE.AIL+CH_TYPE.REVERSE (0x01+0x20=0x21) Reverse Aileron
-- Slave    Example: CH_TYPE.AIL+CH_TYPE.SLAVE (0x01+0x80) -- 2nd servo Aileron

-- Elevon   Example: CH_TYPE.AIL+CH_TYPE.ELE  (0x01+0x02 = 0x03) -- Elevon
-- Elevon   Example: CH_TYPE.AIL+CH_TYPE.ELE+CH_TYPE.SLAVE  (0x01+0x02+0x80 = 0x83) -- Slave Elevon

-- RudElv (VTail) Example: CH_TYPE.ELE+CH_TYPE.RUD  (0x02+0x04 = 0x06) -- Rudevator
-- RudElv (VTail) Example: CH_TYPE.ELE+CH_TYPE.RUD+CH_TYPE.SLAVE  (0x02+0x04+0x80 = 0x86) -- Rudevator Slave

-- DEFAULT Simple Plane Port configuration (The Configuration tool will overrride this)
MODEL.DSM_ChannelInfo= {[0]= -- Start array at position 0
                        {[0]=  CH_MIX_TYPE.NONE, CH_TYPE.THR},    -- Ch1 Thr  (0x40)
                        {[0]=  CH_MIX_TYPE.NONE, CH_TYPE.AIL},    -- Ch2 Ail  (0x01)
                        {[0]=  CH_MIX_TYPE.NONE, CH_TYPE.ELE},    -- Ch2 ElE  (0x02)
                        {[0]=  CH_MIX_TYPE.NONE, CH_TYPE.RUD},    -- Ch4 Rud  (0x04)
                        {[0]=  CH_MIX_TYPE.NONE, CH_TYPE.NONE},   -- Ch5 Gear (0x00)
                        {[0]=  CH_MIX_TYPE.NONE, CH_TYPE.NONE},   -- Ch6 Aux1 (0x00)
                        {[0]=  CH_MIX_TYPE.NONE, CH_TYPE.NONE},   -- Ch7 Aux2 (0x00)
                        {[0]=  CH_MIX_TYPE.NONE, CH_TYPE.NONE},   -- Ch8 Aux3 (0x00)
                        {[0]=  CH_MIX_TYPE.NONE, CH_TYPE.NONE},   -- Ch9 Aux4 (0x00)
                        {[0]=  CH_MIX_TYPE.NONE, CH_TYPE.NONE}    -- Ch10 Aux5 (0x00)
                    }   


------------------------------------------------------------------------------------------------------------
local logCount=0
local function LOG_open()  
    logFile = io.open(LOG_FILE, "w")  -- Truncate Log File 
end

local function LOG_write(...)
    if (logFile==nil) then LOG_open() end
    local str = string.format(...)
    io.write(logFile, str)

    str = string.gsub(str,"\n"," ") -- Elimitate return from line, since print will do it
    print(str)

    if (logCount > 10) then  -- Close an re-open the file
        io.close(logFile)
        logFile = io.open(LOG_FILE, "a")
        logCount =0
    end
end

local function LOG_close()
    if (logFile~=nil) then io.close(logFile) end
end

------------------------------------------------------------------------------------------------------------
-- Get Elapsed Time since we started running the Script. Return a float in format: Seconds.Milliseconds
local function getElapsedTime()
    local t = getTime()
    if (StartTime == 0) then StartTime = t end

    return ((t - StartTime) * 10) / 1000
end

-------------  Line Type helper functions ------------------------------------------------------------------

-- Check if the text are Flight modes, who will be treated different for Display
local function isFlightModeLine(line)
    return (line.TextId >= 0x8000 and line.TextId <= 0x8003)
end

local function isSelectableLine(line)   -- is the display line Selectable??
    -- values who are not selectable
    if (line.Type == 0) then return false end -- Empty Line
    if (line.Type == LINE_TYPE.MENU and line.ValId == line.MenuId and bit32.band(line.TextAttr, DISP_ATTR.FORCED_MENU)==0) then return false end -- Menu that navigates to Itself?
    if (line.Min==0 and line.Max==0 and line.Def==0) then return false end -- Values with no Range are only for display 
    if (line.Type == LINE_TYPE.VALUE_NUM_I8_NC and isFlightModeLine(line)) then return false end -- Flight mode is not Selectable
    return true
end

local function isEditableLine(line) -- is the display line editable??
    -- values who are not editable
    if (line.Type == 0 or line.Type == LINE_TYPE.MENU) then return false end -- Menus are not editable
    if (line.Min==0 and line.Max==0 and line.Def==0) then return false end -- Values with no Range are only for display 
    if (line.Type == LINE_TYPE.VALUE_NUM_I8_NC and isFlightModeLine(line)) then return false end -- Flight mode is not Editable 
    -- any other is Editable
    return true
end

local function isListLine(line)   -- is it a List of options??
    if (line.Type == LINE_TYPE.LIST_MENU_NC or line.Type == LINE_TYPE.LIST_MENU or line.Type == LINE_TYPE.LIST_MENU_TOG) then return true end
    return false
end

local function isPercentValueLineByMinMax(line)
    return
    (line.Min == 0 and  line.Max == 100) or ( line.Min == -100 and  line.Max == 100) or 
    ( line.Min == 0 and  line.Max == 150) or ( line.Min == -150 and  line.Max == 150)
end

local function isPercentValueLine(line)   -- is it a Percent value??
    if (line.Type == LINE_TYPE.VALUE_PERCENT)  then return true end
    return false
end

local function isNumberValueLine(line)     -- is it a number ??
    if (isListLine(line) or line.Type == LINE_TYPE.MENU or line.Type == 0) then return false
    else return true end
end

local function isIncrementalValueUpdate(line)
    if (line.Type == LINE_TYPE.LIST_MENU_NC or line.Type == LINE_TYPE.VALUE_NUM_I8_NC or line.Type == LINE_TYPE.VALUE_DEGREES) then return false end
    return true
end

------------------------------------------------------------------------------------------------------------
local function Get_Text(index)
    local out = Text[index]   -- Find in regular header first
    if (index >= 0x8000) then
        out = Flight_Mode[0]
    end
    if out== nil then
        out = List_Text[index]  -- Try list values, don't think is necesary, but just playing Safe
    end
    if out == nil then -- unknown...
        out = "Unknown_" .. string.format("%X", index)
    end
    return out
end

local function Get_List_Text(index)
    local out = List_Text[index]   -- Try to find the message in List_Text
    if out == nil then
        out = Text[index]  -- Try list headers, don't think is necesary, but just playing Safe
    end
    if out == nil then -- unknown...
        out = "UnknownLT_" .. string.format("%X", index)
    end
    return out
end

local function Get_List_Text_Img(index) 
    local out = List_Text_Img[index]
    return out
end

local function Get_List_Values(index)
    local out = List_Values[index]
    return out
end

------------------------------------------------------------------------------------------------------------
local function Get_RxName(index)
    local out = RxName[index]
    return out or ("Unknown_" .. string.format("%X", index))
end

----------- Debugging 2-String functions -------------------------------------------------------------------

local function phase2String(index)
    local out = PhaseText[index]
    return out or ("Phase_" .. string.format("%X", index))
end

local function lineType2String(index)
    local out = LineTypeText[index]
    return out or ("LT_" .. string.format("%X", index or 0xFF))
end

local function lineValue2String(l)
    if (DEBUG_ON == 0) then
        return ""
    end
    if (l ~= nil and l.Val ~= nil) then
        local value = l.Val
        if isListLine(l) then
            value = value .. "|\"" .. Get_List_Text(l.Val + l.TextStart) .. "\""
        else
            value = value..(l.Format or "")
        end
        return value
    end
    return "nil"
end

local function menu2String(m)
    local txt = "Menu[]"
    if (m ~= nil) then
        txt = string.format("M[Id=0x%X P=0x%X N=0x%X B=0x%X Text=\"%s\"[0x%X]]",
            m.MenuId, m.PrevId, m.NextId, m.BackId, m.Text, m.TextId)
    end
    return txt
end

local function menuLine2String(l)
    local txt = "Line[]"
    if (l ~= nil) then
        local value = ""
        local range = ""
        if l.Type~=LINE_TYPE.MENU then
            value = "Val="..lineValue2String(l)
            if isListLine(l) then
               range = string.format("NL=(%s->%s,%s,S=%s) ",l.Min, l.Max, l.Def, l.TextStart ) 
               range = range .. (l.MinMaxOrig or "")
            else
                range = string.format("[%s->%s,%s]",l.Min, l.Max, l.Def) 
            end    
        end

        txt = string.format("L[#%s T=%s VId=0x%X Text=\"%s\"[0x%X] %s %s MId=0x%X A=0x%X]",
            l.lineNum, lineType2String(l.Type), l.ValId,
            l.Text, l.TextId,
            value,
            range,
            l.MenuId,
            l.TextAttr
        )
    end
    return txt
end

local function channelType2String(byte1, byte2) 
    local s = ""

    if (byte2==0) then return s end;
    if (bit32.band(byte2,CH_TYPE.AIL)>0) then s=s.."AIL " end
    if (bit32.band(byte2,CH_TYPE.ELE)>0) then s=s.."ELE " end
    if (bit32.band(byte2,CH_TYPE.RUD)>0) then s=s.."RUD " end
    if (bit32.band(byte2,CH_TYPE.THR)>0) then s=s.."THR " end
    if (bit32.band(byte2,CH_TYPE.SLAVE)>0) then s=s.."SLAVE " end
    if (bit32.band(byte2,CH_TYPE.REVERSE)>0) then s=s.."REVERSE " end

    if (byte1==CH_MIX_TYPE.NORMAL) then s=s.." MIX_NOR" 
    elseif (byte1==CH_MIX_TYPE.MIX_AIL_B) then s=s.." MIX_AIL_B" 
    elseif (byte1==CH_MIX_TYPE.MIX_ELE_A) then s=s.." MIX_ELE_A" 
    elseif (byte1==CH_MIX_TYPE.MIX_ELE_B_REV) then s=s.." MIX_ELE_B_Rev" 
    elseif (byte1==CH_MIX_TYPE.MIX_ELE_B) then s=s.." MIX_ELE_B" 
    elseif (byte1==CH_MIX_TYPE.MIX_ELE_A_REV) then s=s.." MIX_ELE_A_Rev" 
    elseif (byte1==CH_MIX_TYPE.MIX_AIL_B_REV) then s=s.." MIX_AIL_B_Rev" 
    elseif (byte1==CH_MIX_TYPE.NORM_REV) then s=s.." MIX_NOR_Rev" 
    end

    return s;
end

------------------------------------------------------------------------------------------------------------

local function multiBuffer2String() -- used for debug
    local i
    local rxAnswer = "RX:"
    for i = 10, 25 do
        rxAnswer = rxAnswer .. string.format(" %02X", multiBuffer(i))
    end
    return rxAnswer
end

---------------- DSM Values <-> Int16 Manipulation --------------------------------------------------------

local function int16_LSB(number)  -- Less Significat byte
    local r,x = bit32.band(number, 0xFF)
    return r
end

local function int16_MSB(number) -- Most signifcant byte
    return bit32.rshift(number, 8)
end

local function Dsm_to_Int16(lsb, msb)  -- Componse an Int16 value
    return bit32.lshift(msb, 8) + lsb
end

local function Dsm_to_SInt16(lsb,msb) -- Componse a SIGNED Int16 value
    local value = bit32.lshift(msb, 8) + lsb
    if value >= 0x8000 then  -- Negative value??
        return value - 0x10000
    end
    return value
end

local function sInt16ToDsm(value) -- Convent to SIGNED DSM Value
    if value < 0 then
        value = 0x10000 + value
    end
    return value
end


-----------------------------------------------------------------------------------------------------------
-- Post Procssing Line from Raw values receive by RX or Simulation

local function isDisplayAttr(attr, bit)
    return (bit32.band(attr,bit)>0)
end

local function ExtractDisplayAttr(text1, attr)
    local text = text1, pos;

    for i=1,2 do
        text, pos = string.gsub(text, "/c$", "")
        if (pos>0) then -- CENTER
            attr = bit32.bor(attr, DISP_ATTR._CENTER)
        end

        text, pos = string.gsub(text, "/r$", "")
        if (pos>0) then -- RIGHT
            attr = bit32.bor(attr, DISP_ATTR._RIGHT)
        end

        text, pos = string.gsub(text, "/p$", "")
        if (pos>0) then -- Percent TEXT
            attr = bit32.bor(attr, DISP_ATTR.PERCENT)
        end

        text, pos = string.gsub(text, "/b$", "")
        if (pos>0) then -- BOLD TEXT
            attr = bit32.bor(attr, DISP_ATTR._BOLD)
        end

        text, pos = string.gsub(text, "/m$", "")
        if (pos>0) then -- FORCED MENU Button 
            attr = bit32.bor(attr, DISP_ATTR.FORCED_MENU)
        end
    end

    return text, attr 
end

local function DSM_MenuPostProcessing(menu)
    menu.Text, menu.TextAttr =  ExtractDisplayAttr(menu.Text,menu.TextAttr or 0)
end

local function DSM_MenuLinePostProcessing(line)
    if (line.Text==nil) then
        line.Text   = Get_Text(line.TextId) -- Get Textual Line headeing text 
    end

    -- Text formatting options
    line.Text, line.TextAttr = ExtractDisplayAttr(line.Text,line.TextAttr or 0)

    if line.Type == LINE_TYPE.MENU then
        -- nothing to do on menu entries
        line.Val=nil
    elseif isListLine(line) then
        -- Original Range  for Debugging
        line.MinMaxOrig = "[" .. line.Min .. "->" .. line.Max .. "," .. line.Def .. "]"

        -- Normalize Min/Max to be relative to Zero
        line.TextStart = line.Min
        line.Def = line.Def - line.Min -- normalize default value 
        line.Max = line.Max - line.Min -- normalize max index
        line.Min = 0 -- min index
    else -- default to numerical value
        if isPercentValueLine(line) or isPercentValueLineByMinMax(line) then
            -- either explicit Percent or NO-Change value, but range is %Percent
            line.Format ="%"
            line.TextAttr = bit32.bor(line.TextAttr,DISP_ATTR.PERCENT)
        elseif (line.Type == LINE_TYPE.VALUE_DEGREES) then
            line.Format ="o"
            line.TextAttr = bit32.bor(line.TextAttr,DISP_ATTR.DEGREES)
        end
    end

    line.MinMaxDebug =  lineType2String(line.Type).."  "..(line.MinMaxOrig or "")
end

------------------------------------------------------------------------------------------------------------
local function DSM_send(...)
    local arg = { ... }
   
    for i = 1, #arg do
        multiBuffer(3 + i, arg[i])
    end
    multiBuffer(3, 0x70 + #arg)


    if (DEBUG_ON > 1) then 
        local str = ""
        for i = 1, #arg do
            str = str .. string.format("%02X ", arg[i]) 
        end
        LOG_write("DSM_SEND: [%s]\n", str) 
    end
end

-------------------------------------------------------------------------------------------------
-- Read the model information from OTX/ETX

local function getModuleChannelOrder(num) 
      --Determine fist 4 channels order
  local channel_names={}
  local stick_names = {[0]= "R", "E", "T", "A" }
  local ch_order=num
  if (ch_order == -1) then
    channel_names[0] = stick_names[3]
    channel_names[1] = stick_names[1]
    channel_names[2] = stick_names[2]
    channel_names[3] = stick_names[0]
  else
    channel_names[bit32.band(ch_order,3)] = stick_names[3]
    ch_order = math.floor(ch_order/4)
    channel_names[bit32.band(ch_order,3)] = stick_names[1]
    ch_order = math.floor(ch_order/4)
    channel_names[bit32.band(ch_order,3)] = stick_names[2]
    ch_order = math.floor(ch_order/4)
    channel_names[bit32.band(ch_order,3)] = stick_names[0]
  end

  local s = ""
  for i=0,3 do
    s=s..channel_names[i]
  end
  return s
end

local function DSM_ReadTxModelData()
    local TRANSLATE_AETR_TO_TAER=false
    local table = model.getInfo()   -- Get the model name 
    MODEL.modelName = table.name

    local module = model.getModule(0) -- Internal
    if (module==nil) then module = model.getModule(1) end -- External
    if (module~=nil) then
        if (module.Type==6 ) then -- MULTI-MODULE
            local chOrder = module.channelsOrder
            local s = getModuleChannelOrder(chOrder)
            LOG_write("MultiChannel Ch Order: [%s]  %s\n",chOrder,s) 

            if (s=="AETR") then TRANSLATE_AETR_TO_TAER=true 
            else TRANSLATE_AETR_TO_TAER=false 
            end
        end
    end

    LOG_write("MODEL NAME = %s\n",MODEL.modelName) 

    -- Read Ch1 to Ch10
    local i= 0
    for i = 0, 12 do 
        local ch = model.getOutput(i) -- Zero base 
        if (ch~=nil) then
            MODEL.modelOutputChannel[i] = ch
            if (string.len(ch.name)==0) then 
                ch.formatCh = string.format("TX:Ch%i",i+1)
            else
                ch.formatCh = string.format("TX:Ch%i/%s",i+1,ch.name or "--")
            end
        end
    end

    -- Translate AETR to TAER
    -- TODO: Check if there is a way to know how to the TX is configured, since if it is 
    -- already TAER, is not needed 

    if (TRANSLATE_AETR_TO_TAER) then 
        LOG_write("Applying  AETR -> TAER translation\n") 
        local ail = MODEL.modelOutputChannel[0]
        local elv = MODEL.modelOutputChannel[1]
        local thr = MODEL.modelOutputChannel[2]

        MODEL.modelOutputChannel[0] = thr
        MODEL.modelOutputChannel[1] = ail
        MODEL.modelOutputChannel[2] = elv
    end

    -- Create the Port Text to be used 
    LOG_write("Ports/Channels:\n") 
    for i = 0, 9 do 
        local ch =  MODEL.modelOutputChannel[i]
        if (ch~=nil) then
            MODEL.TX_CH_TEXT[i] = ch.formatCh
            if LCD_W <= 128 then -- SMALLER SCREENS
                MODEL.PORT_TEXT[i] = string.format("P%i (%s) ",i+1,MODEL.TX_CH_TEXT[i])
            else
                MODEL.PORT_TEXT[i] = string.format("Port%i (%s) ",i+1,MODEL.TX_CH_TEXT[i])
            end
            
            LOG_write("Port%d %s [%d,%d] Rev=%d, Off=%d, ppmC=%d, syn=%d\n",i+1,MODEL.TX_CH_TEXT[i],math.floor(ch.min/10),math.floor(ch.max/10), ch.revert, ch.offset, ch.ppmCenter, ch.symetrical)
        end
    end
end

local function DSM_SetDSMChannelInfo(channelInfo, description)
    MODEL.DSM_ChannelInfo = channelInfo

    LOG_write("Current Model Generated Port Configuration\n")
    LOG_write("Description:%s\n",description)
    for i = 0, 9 do 
        local b1, b2 = channelInfo[i][0], channelInfo[i][1]
        LOG_write("%s (0x%02X, 0x%02X) = %s \n",MODEL.PORT_TEXT[i],b1,b2, channelType2String(b1,b2))
    end
end

-------------------------------------------------------------------------------------------------
local function DSM_StartConnection()
    if (DEBUG_ON) then LOG_write("DSM_StartConnection()\n") end
    
    --Set protocol to talk to
    multiBuffer( 0, string.byte('D') )
    --test if value has been written
    if multiBuffer( 0 ) ~=  string.byte('D') then
    if (DEBUG_ON) then LOG_write("Not Enouth memory\n") end
        error("Not enough memory!")
        return 2
    end
    --Init TX buffer
    multiBuffer( 3, 0x00 )
    --Init RX buffer
    multiBuffer( 10, 0x00 )
    --Init telemetry
    multiBuffer( 0, string.byte('D') )
    multiBuffer( 1, string.byte('S') )
    multiBuffer( 2, string.byte('M') ) 

    return 0
end

local function DSM_ReleaseConnection()
    if (DEBUG_ON) then LOG_write("DSM_ReleaseConnection()\n") end
    multiBuffer(0, 0)
    DSM_Context.Phase = PHASE.EXIT_DONE
end

local function DSM_ChangePhase(newPhase)
    DSM_Context.Phase = newPhase
    Waiting_RX = 0
end

local function DSM_Value_Add(line, inc)
    if (DEBUG_ON) then LOG_write("%3.3f %s: DSM_Value_Add(%s,%s)\n", getElapsedTime(), phase2String(DSM_Context.Phase), inc, menuLine2String(line)) end
    local skipIncrement = false
    local values  = nil
    local origVal = line.Val

    -- Use local validation for LIST_MENU1 when the range is wide open 
    -- Also use if for some LIST_MENU0 that the Range seems incorrect
    if (isListLine(line)) then -- and line.Type==LINE_TYPE.LIST_MENU1 and line.Min==0 and line.Max==244) then
        values = Get_List_Values(line.TextId)
    end

    
    if (values~=nil) then  -- Inc/Dec based on a list of predefined Values Local to Script (values not contiguous), 
        -- locate current value in values array 
        -- Values are Zero normalized to the Start of the List (line.TextStart)
        for i = 1, #values do
            if ((values[i]-line.TextStart)==origVal) then
                skipIncrement = true
                if (inc==-1 and i > 1) then -- PREV
                    line.Val = values[i-1]-line.TextStart
                elseif (inc==1 and i < #values) then -- NEXT
                    line.Val = values[i+1]-line.TextStart
                end
                break
            end
        end
    end

    if not skipIncrement then
        -- Do it Sequentially
        line.Val = line.Val + inc

        if line.Val > line.Max then
            line.Val = line.Max
        elseif line.Val < line.Min then
            line.Val = line.Min
        end
    end

    if (origVal~=line.Val and isIncrementalValueUpdate(line)) then 
        -- Update RX value on every change 
        DSM_ChangePhase(PHASE.VALUE_CHANGING)
    end
end

local function DSM_Value_Default(line)
    local origVal = line.Val
    if (DEBUG_ON) then LOG_write("%3.3f %s: DSM_Value_Default(%s)\n", getElapsedTime(), phase2String(DSM_Context.Phase), menuLine2String(line)) end

    line.Val = line.Def
    if (origVal~=line.Val and isIncrementalValueUpdate(line)) then 
        -- Update RX value on every change 
        DSM_ChangePhase(PHASE.VALUE_CHANGING)
    end
end

local function DSM_Value_Write_Validate(line)
    if (DEBUG_ON) then LOG_write("%3.3f %s: DSM_Value_Write_Validate(%s)\n", getElapsedTime(), phase2String(DSM_Context.Phase), menuLine2String(line)) end
    DSM_ChangePhase(PHASE.VALUE_CHANGE_END) -- Update + Validate value in RX 
    DSM_Context.EditLine = nil   -- Exit Edit Mode (By clearing the line editing)
end

local function DSM_GotoMenu(menuId, lastSelectedLine)
    if (DEBUG_ON) then LOG_write("%3.3f %s: DSM_GotoMenu(0x%X,LastSelectedLine=%d)\n", getElapsedTime(), phase2String(DSM_Context.Phase), menuId, lastSelectedLine) end
    DSM_Context.Menu.MenuId = menuId
    DSM_Context.SelLine = lastSelectedLine
    -- Request to load the menu Again
    DSM_ChangePhase(PHASE.MENU_TITLE)
end

local function DSM_MoveSelectionLine(dir)
    local ctx = DSM_Context
    local menu = ctx.Menu
    local menuLines = ctx.MenuLines

    if (dir == 1) then -- NEXT
        if ctx.SelLine <= MAX_MENU_LINES then
            local num = ctx.SelLine
            for i = ctx.SelLine + 1, MAX_MENU_LINES, 1 do
                if isSelectableLine(menuLines[i]) then
                    ctx.SelLine = i
                    break
                end
            end

            if num == ctx.SelLine then
                if menu.NextId ~= 0 then -- Next
                    ctx.SelLine = NEXT_BUTTON
                elseif menu.PrevId ~= 0 then -- Prev
                    ctx.SelLine = PREV_BUTTON
                end
            end
        elseif menu.PrevId ~= 0 then -- Prev
            ctx.SelLine = PREV_BUTTON
        end
        return
    end

    if (dir == -1) then -- PREV 
        if ctx.SelLine == PREV_BUTTON and menu.NextId ~= 0 then
            ctx.SelLine = NEXT_BUTTON
        elseif ctx.SelLine > 0 then
            if ctx.SelLine > MAX_MENU_LINES then
                ctx.SelLine = NEXT_BUTTON
            end
            local num = ctx.SelLine
            for i = ctx.SelLine - 1, 0, -1 do
                if isSelectableLine(menuLines[i]) then
                    ctx.SelLine = i
                    break
                end
            end
            if num == ctx.SelLine then -- can't find previous selectable line, then SELECT  Back
                if (menu.BackId ~= 0) then ctx.SelLine = BACK_BUTTON end
            end
        else
            if (menu.BackId ~= 0) then ctx.SelLine = BACK_BUTTON end -- Back 
        end
    end
end
--------------------------------------------------------------------------------------------------------
-- REEQUEST Messages to RX

local function DSM_sendHeartbeat()
    -- keep connection open
    if (DEBUG_ON) then LOG_write("SEND DSM_sendHeartbeat()\n") end
    DSM_send(0x00, 0x04, 0x00, 0x00)
end

local function DSM_getRxVerson()
    if (DEBUG_ON) then LOG_write("SEND DSM_getRxVersion()\n") end
    DSM_send(0x11, 0x06, 0x00, 0x14, 0x00, 0x00)
end

local function DSM_getMainMenu()
    if (DEBUG_ON) then LOG_write("SEND DSM_getMainMenu()\n") end
    DSM_send(0x12, 0x06, 0x00, 0x14, 0x00, 0x00) -- first menu only
end

local function DSM_getMenu(menuId, latSelLine)
    if (DEBUG_ON) then LOG_write("SEND DSM_getMenu(MenuId=0x%X LastSelectedLine=%s)\n", menuId, latSelLine) end
    DSM_send(0x16, 0x06, int16_MSB(menuId), int16_LSB(menuId), 0x00, latSelLine)
end

local function DSM_getFirstMenuLine(menuId)
    if (DEBUG_ON) then LOG_write("SEND DSM_getFirstMenuLine(MenuId=0x%X)\n", menuId) end
    DSM_send(0x13, 0x04, int16_MSB(menuId), int16_LSB(menuId)) -- line 0
end

local function DSM_getNextMenuLine(menuId, curLine)
    if (DEBUG_ON) then LOG_write("SEND DSM_getNextLine(MenuId=0x%X,LastLine=%s)\n", menuId, curLine) end
    DSM_send(0x14, 0x06, int16_MSB(menuId), int16_LSB(menuId), 0x00, curLine) -- line X
end

local function DSM_getNextMenuValue(menuId, valId, text)
    if (DEBUG_ON) then LOG_write("SEND DSM_getNextMenuValue(MenuId=0x%X, LastValueId=0x%X) Extra: Text=\"%s\"\n", menuId, valId,
            text)
    end
    DSM_send(0x15, 0x06, int16_MSB(menuId), int16_LSB(menuId), int16_MSB(valId), int16_LSB(valId)) -- line X
end

local function DSM_updateMenuValue(valId, val, text, line)
    local value = sInt16ToDsm(val)
    if (DEBUG_ON) then LOG_write("SEND DSM_updateMenuValue(ValueId=0x%X,val=%d) Extra: Text=\"%s\" Value=%s\n", valId, val, text, lineValue2String(line)) end
    DSM_send(0x18, 0x06, int16_MSB(valId), int16_LSB(valId), int16_MSB(value), int16_LSB(value)) -- send current value
end

local function DSM_validateMenuValue(valId, text, line)
    if (DEBUG_ON) then LOG_write("SEND DSM_validateMenuValue(ValueId=0x%X) Extra: Text=\"%s\" Value=%s\n", valId, text, lineValue2String(line)) end
    DSM_send(0x19, 0x04, int16_MSB(valId), int16_LSB(valId)) 
end

local function DSM_menuValueChangingWait(lineNum, text, line)
    if (DEBUG_ON) then LOG_write("SEND DSM_menuValueChangingWait(lineNo=0x%X) Extra: Text=\"%s\"  Val=%s\n", lineNum, text, lineValue2String(line)) end
    DSM_send(0x1A, 0x04, int16_MSB(lineNum), int16_LSB(lineNum))
end

local function DSM_menuValueChangingWaitEnd(lineNum, text, line)
    if (DEBUG_ON) then LOG_write("SEND DSM_menuValueChangingEnd(lineNo=0x%X) Extra: Text=\"%s\"  Value=%s\n", lineNum, text, lineValue2String(line)) end
    DSM_send(0x1B, 0x04, int16_MSB(lineNum), int16_LSB(lineNum))
end

-- Send the functionality of the RX channel Port (channel)
local function DSM_sendTxChInfo_20(portNo)
    local b1,b2 =  MODEL.DSM_ChannelInfo[portNo][0], MODEL.DSM_ChannelInfo[portNo][1]

    if (DEBUG_ON) then LOG_write("CALL DSM_TxChInfo_20(#%d %s DATA= %02X %02X %02X %02X)  CONTEXT: %s\n", portNo, MODEL.PORT_TEXT[portNo],
        portNo, portNo, b1, b2, channelType2String(b1,b2)) -- DATA part
    end
    DSM_send(0x20, 0x06, portNo, portNo, b1, b2) 
end

local function DSM_sendTxSubtrim_21(portNo)
    --SubTrim is encoded as an offset of the pulse width. 

    local data = {[0]= -- Start at 0
        {[0]= 0x0, 0x00, 0x07, 0xFF }, -- Ch1 Thr:     0 00 07 FF   Subtrim ??
        {[0]= 0x0, 0x8E, 0x07, 0x72 }, -- Ch2 Ail:     0 8E 07 72   Subtrim 0
        {[0]= 0x0, 0x8E, 0x07, 0x72 }, -- Ch3 Elev:    0 8E 07 72   Subtrim 0
        {[0]= 0x0, 0x8E, 0x07, 0x72 }, -- Ch4 Rud:     0 8E 07 72   Subtrim 0
        {[0]= 0x0, 0x8E, 0x07, 0x72 }, -- Ch5 Gear:    0 8E 07 72   Subtrim 0
        {[0]= 0x0, 0x8E, 0x07, 0x72 }, -- Ch6 Aux1:    0 8E 07 72   Subtrim 0
        {[0]= 0x0, 0x8E, 0x07, 0x72 }, -- Ch7 Aux2:    0 8E 07 72   Subtrim 0
        {[0]= 0x0, 0x8E, 0x07, 0x72 }, -- Ch8 Aux3:    0 8E 07 72   Subtrim 0
        {[0]= 0x0, 0x8E, 0x07, 0x72 }, -- Ch9 Aux4:    0 8E 07 72   Subtrim 0
        {[0]= 0x0, 0x8E, 0x07, 0x72 }, -- Ch10 Aux5:   0 8E 07 72   Subtrim 0
    }

    local b1,b2,b3,b4 = data[portNo][0], data[portNo][1], data[portNo][2], data[portNo][3]

    if (DEBUG_ON) then LOG_write("CALL DSM_TxSubtrim_21(#%d %s DATA=%02X %02X %02X %02X)\n", portNo, MODEL.PORT_TEXT[portNo],
        b1,b2,b3,b4) -- DATA part
   end
   DSM_send(0x21, 0x06, b1,b2,b3,b4) -- Port is not send anywhere, since the previous 0x20 type message have it.
end

local function DSM_sendTxServoTravel_23(portNo)
    local leftTravel =   math.abs(math.floor(MODEL.modelOutputChannel[portNo].min/10))
    local rightTravel =  math.abs(math.floor(MODEL.modelOutputChannel[portNo].max/10))
    local debugInfo   = string.format("Travel L/R (%d - %d)",leftTravel,rightTravel)

    if (DEBUG_ON) then LOG_write("CALL DSM_TxServoTravel_23(#%d %s DATA= %02X %02X %02X %02X)   CONTEXT: %s\n", portNo, MODEL.PORT_TEXT[portNo],
        0x00, leftTravel, 0x00, rightTravel, debugInfo) -- DATA part
    end
    DSM_send(0x23, 0x06, 0x00, leftTravel, 0x00, rightTravel)
end

local function DSM_sentTxInfo(menuId,portNo)
        -- TxInfo_Type=0    : AR636B Main Menu (Send port/Channel info + SubTrim + Travel)
        -- TxInfo_Type=1    : AR630-637 Famly Main Menu  (Only Send Port/Channel usage Msg 0x20)
        -- TxInfo_Type=1F   : AR630-637 Initial Setup/Relearn Servo Settings (Send port/Channel info + SubTrim + Travel +0x24/Unknown)

        if (TxInfo_Step == 0) then  
            -- AR630 family: Both TxInfo_Type (ManinMenu=0x1,   Other First Time Configuration = 0x1F)
            DSM_sendTxChInfo_20(portNo)

            if (TxInfo_Type == 0x1F) then
                Waiting_RX = 0 -- keep Transmitig
                TxInfo_Step = 1
            end 
            if (TxInfo_Type == 0x00) then
                Waiting_RX = 0 -- keep Transmitig
                TxInfo_Step = 2
            end 
        elseif (TxInfo_Step == 1) then
            DSM_sendTxServoTravel_23(portNo)
           TxInfo_Step = 2
           Waiting_RX = 0 -- keep Transmitig
        elseif (TxInfo_Step == 2) then
            DSM_sendTxSubtrim_21(portNo)

            Waiting_RX = 0 -- keep Transmitig
            if (TxInfo_Type == 0x00) then
                TxInfo_Step = 5 -- End Step 
            else 
                TxInfo_Step = 3
           end
        elseif (TxInfo_Step == 3) then
            -- 24,6: 0 83 5A B5 
            if (DEBUG_ON) then LOG_write("CALL DSM_TxInfo_24(#%d DATA=0x24 0x06 %02X %02X %02X %02X)\n", portNo,
                0x00, 0x83, 0x5A, 0xB5) -- DATA part
           end
           DSM_send(0x24, 0x06, 0x00, 0x83, 0x5A, 0xB5) -- Still Uknown
           TxInfo_Step = 4
           Waiting_RX = 0 -- keep Transmitig
        elseif (TxInfo_Step == 4) then
            -- 24,6: 6 80 25 4B 
            if (DEBUG_ON) then LOG_write("CALL DSM_TxInfo_24(#%d DATA=0x24 0x06 %02X %02X %02X %02X)\n", portNo,
                0x06, 0x80, 0x25, 0x4B) -- DATA part
           end
           DSM_send(0x24, 0x06, 0x06, 0x80, 0x25, 0x4B)  -- Still Uknown
           TxInfo_Step = 5
           Waiting_RX = 0 -- keep Transmitig
        elseif (TxInfo_Step == 5) then
            -- 22,4: 0 0 
            if (DEBUG_ON) then LOG_write("CALL DSM_TxInfo_End_22(#%d DATA=%02X %02X)\n", portNo,
                0x00, 0x00) -- DATA part
           end
           DSM_send(0x22, 0x04, 0x00, 0x00)
           TxInfo_Step = 6
        end
end

-----------------------------------------------------------------------------------------------------------
    
local function DSM_sendRequest()  
    -- Send the proper Request message depending on the Phase 
    
    local ctx = DSM_Context
    if (DEBUG_ON) then LOG_write("%3.3f %s: ", getElapsedTime(), phase2String(ctx.Phase)) end

    if ctx.Phase == PHASE.RX_VERSION then -- request RX version
        DSM_getRxVerson()

    elseif ctx.Phase == PHASE.WAIT_CMD then -- keep connection open
        DSM_sendHeartbeat()

    elseif ctx.Phase == PHASE.MENU_TITLE then -- request menu title
        if ctx.Menu.MenuId == 0 then  -- First time loading a menu ?
            DSM_getMainMenu()
        else
            DSM_getMenu(ctx.Menu.MenuId, ctx.SelLine) 

            if (ctx.Menu.MenuId == 0x0001) then  -- Executed the Reset Menu??
                if (DEBUG_ON) then LOG_write("RX Reset!!!\n") end
                -- Start again retriving RX info 
                ctx.Menu.MenuId = 0
                ctx.isReset = true                
                ctx.Phase = PHASE.RX_VERSION
            end
        end

    elseif ctx.Phase == PHASE.MENU_REQ_TX_INFO then 
        DSM_sentTxInfo(ctx.Menu.MenuId, ctx.CurLine)

    elseif ctx.Phase == PHASE.MENU_LINES then -- request next menu lines
        if ctx.CurLine == -1 then -- No previous menu line loaded ?
            DSM_getFirstMenuLine(ctx.Menu.MenuId)
        else
            DSM_getNextMenuLine(ctx.Menu.MenuId, ctx.CurLine)
        end

    elseif ctx.Phase == PHASE.MENU_VALUES then -- request menu values
        local line = ctx.MenuLines[ctx.CurLine]
        DSM_getNextMenuValue(ctx.Menu.MenuId, line.ValId, line.Text)

    elseif ctx.Phase == PHASE.VALUE_CHANGING then -- send value
        local line = ctx.MenuLines[ctx.SelLine] -- Updated Value of SELECTED line       
        DSM_updateMenuValue(line.ValId, line.Val, line.Text, line)
        ctx.Phase = PHASE.VALUE_CHANGING_WAIT

    elseif ctx.Phase == PHASE.VALUE_CHANGING_WAIT then
        local line = ctx.MenuLines[ctx.SelLine]
        DSM_menuValueChangingWait(line.lineNum, line.Text, line)

    elseif ctx.Phase == PHASE.VALUE_CHANGE_END then -- send value
        -- This is a 2 step operation.. Send the value first, then send the Verification.. Value_Changed_Step used for that
        -- on the validation, the RX will set a valid value if the value is invalid. A Menu_Value Message will come from the RX 

        local line = ctx.MenuLines[ctx.SelLine] -- Update Value of SELECTED line
        if Value_Change_Step == 0 then  
            DSM_updateMenuValue(line.ValId, line.Val, line.Text, line)
            Value_Change_Step = 1
            Waiting_RX = 0 -- Keep on Transmitin State, since we want to send a ValidateMenuValue inmediatly after
        elseif Value_Change_Step == 1 then -- Validate the value
            DSM_validateMenuValue(line.ValId, line.Text, line)
            Value_Change_Step = 2
            Waiting_RX = 0 -- Keep on Transmitin State, since we want to send a ValidateMenuValue inmediatly after
        else  -- No more waiting for changes
            DSM_menuValueChangingWaitEnd(line.lineNum, line.Text, line)
            Value_Change_Step = 0
        end

    
    elseif ctx.Phase == PHASE.EXIT then
        if (DEBUG_ON) then LOG_write("CALL DSM_exitRequest()\n") end
        DSM_send(0x1F, 0x02, 0xAA)
    end
end

-----------------------------------------------------------------------------------------------------------
-- Parsing Responses

local function DSM_parseRxVersion()
    --ex: 0x09 0x01 0x00 0x15 0x02 0x22 0x01 0x00 0x14 0x00 0x00 0x00 0x00 0x00 0x00 0x00
    local rxId = multiBuffer(13)
    DSM_Context.RX.Id = rxId
    DSM_Context.RX.Name = Get_RxName(rxId)
    DSM_Context.RX.Version = multiBuffer(14) .. "." .. multiBuffer(15) .. "." .. multiBuffer(16)
    if (DEBUG_ON) then LOG_write("RESPONSE Receiver=%s Version %s\n", DSM_Context.RX.Name, DSM_Context.RX.Version) end
end

local function DSM_parseMenu()
    --ex: 0x09 0x02 0x4F 0x10  0xA5 0x00 0x00 0x00 0x50 0x10 0x10 0x10 0x00 0x00 0x00 0x00
    --              MenuID     TextID    PrevID    NextID    BackID
    local ctx = DSM_Context
    local menu  = ctx.Menu
    menu.MenuId = Dsm_to_Int16(multiBuffer(12), multiBuffer(13))
    menu.TextId = Dsm_to_Int16(multiBuffer(14), multiBuffer(15))
    menu.Text   = Get_Text(menu.TextId)
    menu.PrevId = Dsm_to_Int16(multiBuffer(16), multiBuffer(17))
    menu.NextId = Dsm_to_Int16(multiBuffer(18), multiBuffer(19))
    menu.BackId = Dsm_to_Int16(multiBuffer(20), multiBuffer(21))
    for i = 0, MAX_MENU_LINES do -- clear menu
        ctx.MenuLines[i] = { MenuId = 0, lineNum = 0, Type = 0, Text = "", TextId = 0, ValId = 0, Min=0, Max=0, Def=0, Val=nil }
    end
    ctx.CurLine = -1

    DSM_MenuPostProcessing(menu)

    if (DEBUG_ON) then LOG_write("RESPONSE Menu: %s\n", menu2String(menu)) end
    return menu
end


local function DSM_parseMenuLine()
    --ex: 0x09 0x03 0x00    0x10      0x00  0x1C  0xF9 0x00   0x10    0x10      0x00 0x00 0x00 0x00 0x03 0x00
    --ex: 0x09 0x03 0x61    0x10      0x00  0x6C  0x50 0x00   0x00    0x10      0x36 0x00 0x49 0x00 0x36 0x00
    --ex: 0x09 0x03 0x65    0x10      0x00  0x0C  0x51 0x00   0x00    0x10      0x00 0x00 0xF4 0x00 0x2E 0x00
    --              MenuLSB MenuMSB   line  Type  TextID      NextLSB NextMSB   Val_Min   Val_Max   Val_Def

    local ctx = DSM_Context
    local i = multiBuffer(14)
    local type = multiBuffer(15)
    local line = ctx.MenuLines[i]

    -- are we trying to override existing line
    if (line.Type > 0 and type == 0) then
        if (DEBUG_ON) then LOG_write("RESPONSE MenuLine: ERROR. Trying to Override: %s\n", menuLine2String(line)) end
        return line
    end

    ctx.CurLine = i

    line.lineNum = i
    line.MenuId = Dsm_to_Int16(multiBuffer(12), multiBuffer(13))
    line.Type   = type
    line.TextId = Dsm_to_Int16(multiBuffer(16), multiBuffer(17))
    line.Text   = nil -- Fill at Post processing
    line.ValId  = Dsm_to_Int16(multiBuffer(18), multiBuffer(19))

    -- Singed int values
    line.Min = Dsm_to_SInt16(multiBuffer(20), multiBuffer(21))  
    line.Max = Dsm_to_SInt16(multiBuffer(22), multiBuffer(23)) 
    line.Def = Dsm_to_SInt16(multiBuffer(24), multiBuffer(25))

    DSM_MenuLinePostProcessing(line)

    if (DEBUG_ON) then LOG_write("RESPONSE MenuLine: %s\n", menuLine2String(line))  end
    return line
end

local function DSM_parseMenuValue()
    --ex: 0x09 0x04 0x53    0x10    0x00    0x10    0x00    0x00  0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00
    --ex: 0x09 0x04 0x61    0x10    0x02    0x10    0x01    0x00  0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00
    --              MenuLSB MenuMSB ValLSB  ValMSB  V_LSB   V_MSB

    -- Identify the line and update the value
    local ctx = DSM_Context
    local valId = Dsm_to_Int16(multiBuffer(14), multiBuffer(15))
    local value = Dsm_to_SInt16(multiBuffer(16), multiBuffer(17)) --Signed int 

    local updatedLine = nil
    for i = 0, MAX_MENU_LINES do -- Find the menu line for this value
        local line = ctx.MenuLines[i]
        if line ~= nil and line.Type ~= 0 then
            if line.Type ~= LINE_TYPE.MENU and line.ValId == valId then -- identifier of ValueId stored in the line
                line.Val = value
                ctx.CurLine = i
                updatedLine = line
                break
            end
        end
    end

    if (updatedLine == nil) then
        if (DEBUG_ON) then LOG_write("ERROR, Cant find Menu Line with ValID=%X to update\n", valId) end
    else
        if (DEBUG_ON) then LOG_write("RESPONSE MenuValue: UPDATED: %s\n", menuLine2String(updatedLine))
        end
    end
end

local function DSM_parseReqTxInfo() 
    -- unknown... I think is trying to request info about TX (Wing type, etc)
    -- 0x09 0x05 0x01   0x01 0x00   0x00 0x00 0x00 0x07   Menu: MAIN MENU
    -- 0x09 0x05 0x01   0x1F 0x00   0x00 0x00 0x00 0x07   Menu: First Time Setup
    --           Line   ??                   ????
    local portNo = multiBuffer(12)
    TxInfo_Type   = multiBuffer(13)
    if (DEBUG_ON) then LOG_write("RESPONSE ReqTXChannelInfo(#%d DataType=0x%0X  DATA=%s)\n", portNo, TxInfo_Type, multiBuffer2String()) end

    TxInfo_Step = 0

    return portNo
end


-- Creates a fake line do display an error in the GUI
local function DSM_Add_Error_Menu_Line(i, text)
    local ctx = DSM_Context
    local line = ctx.MenuLines[i]
    ctx.CurLine = i

    line.lineNum = i
    line.MenuId = ctx.Menu.MenuId
    line.Type = LINE_TYPE.MENU
    line.TextId = 0
    line.Text = text 
    line.ValId = ctx.Menu.MenuId

    -- Singed int values
    line.Min =0
    line.Max = 0
    line.Def = 0

    line.MinMaxOrig = ""
    line.Val = nil

    DSM_MenuLinePostProcessing(line)
end

------------------------------------------------------------------------------------------------------------
local function DSM_processResponse()
    local ctx = DSM_Context
    local cmd = multiBuffer(11) -- Response Command

    if (DEBUG_ON > 1) then LOG_write("%s: RESPONSE %s \n", phase2String(ctx.Phase), multiBuffer2String()) end
    if (DEBUG_ON and cmd > 0x00) then LOG_write("%3.3f %s: ", getElapsedTime(), phase2String(ctx.Phase)) end

    if cmd == 0x01 then -- read version
        DSM_parseRxVersion()
        Lib.Init_Text(DSM_Context.RX.Id)
        ctx.isReset = false  -- no longer resetting  
        ctx.Phase = PHASE.MENU_TITLE

    elseif cmd == 0x02 then -- read menu title
        local menu = DSM_parseMenu()

        -- Update Selected Line navigation
        if menu.NextId ~= 0 then
            ctx.SelLine = NEXT_BUTTON -- highlight Next
        else
            ctx.SelLine = BACK_BUTTON -- highlight Back
        end

        if (ctx.Menu.MenuId == 0x0001) then  -- Still in RESETTING MENU???
            -- Star from Start
            if (DEBUG_ON) then LOG_write("RX Reset:  Still not done, restart again!!!\n") end
            ctx.Menu.MenuId = 0
            ctx.Phase = PHASE.RX_VERSION
        else
            ctx.Phase = PHASE.MENU_LINES
        end
        

    elseif cmd == 0x03 then --  menu lines
        local line = DSM_parseMenuLine()

        -- Update Selected line navigation
        if (ctx.SelLine == BACK_BUTTON or ctx.SelLine == NEXT_BUTTON or ctx.SelLine == PREV_BUTTON)
            and isSelectableLine(line) then -- Auto select the current line
            ctx.SelLine = line.lineNum
        end

        ctx.Phase = PHASE.MENU_LINES

    elseif cmd == 0x04 then -- read menu values
        DSM_parseMenuValue()
        ctx.Phase = PHASE.MENU_VALUES
        
    elseif cmd == 0x05 then -- Request TX Info
        local portNo = DSM_parseReqTxInfo() 

        if (portNo==ctx.CurLine) then
            -- WEIRD BEHAVIOR
            -- We got the same line we already got. thi will continue
            -- on a loop and disconnect RX 
            DSM_Add_Error_Menu_Line(0,"\bError: Cannot Load Menu Lines from RX")
            if (DEBUG_ON) then LOG_write("ERROR: Received Same menu line\n") end
        end -- Got the next line.. keep requesting more
            
        ctx.CurLine = portNo
        ctx.Phase = PHASE.MENU_REQ_TX_INFO

    elseif cmd == 0xA7 then -- answer to EXIT command
        if (DEBUG_ON) then LOG_write("RESPONSE Exit Confirm\n") end
        DSM_ReleaseConnection()

    elseif cmd == 0x00 then -- NULL response (or RX heartbeat)
        if (ctx.Phase == PHASE.WAIT_CMD) then -- Dont show null while waiting for command to no fill the logs
            if (DEBUG_ON > 1) then LOG_write("%3.3f %s: RESPONSE NULL\n", getElapsedTime(), phase2String(ctx.Phase)) end
        else
            if (DEBUG_ON) then LOG_write("%3.3f %s: RESPONSE NULL\n", getElapsedTime(), phase2String(ctx.Phase)) end
        end

        if (ctx.Phase == PHASE.VALUE_CHANGING) then
            ctx.Phase = PHASE.VALUE_CHANGING_WAIT
        end
    else
        if (DEBUG_ON) then LOG_write("RESPONSE Unknown Command (0x%X)  DATA=%s\n", cmd, multiBuffer2String()) end
    end

    return cmd
end

------------------------------------------------------------------------------------------------------------
local function DSM_Send_Receive()
    local context = DSM_Context

    if Waiting_RX == 0 then   -- Need to send a request
        Waiting_RX = 1
        DSM_sendRequest()

        multiBuffer(10, 0x00) -- Clear Response Buffer
        InactivityTime = getTime() + SEND_TIMEOUT  -- Reset Inactivity timeout 
    elseif multiBuffer(10) == 0x09 then -- RX data available
        local cmd = DSM_processResponse()

        multiBuffer(10, 0x00) -- Clear Response Buffer to know that we are done with the response

        if (cmd > 0x00) then -- Any non NULL response
            -- Only change to SEND mode if we received a valid response  (Ignore NULL Responses, that are really heartbeat i most cases)
            Waiting_RX = 0
            InactivityTime = getTime() + SEND_TIMEOUT  -- Reset Inactivity timeout 
            context.Refresh_Display = true
        end
    else
        -- Check if enouth time has passed from last transmit/receive activity
        if getTime() > InactivityTime then
            if (DEBUG_ON) then LOG_write("%3.3f %s: INACTIVITY TIMEOUT\n", getElapsedTime(), phase2String(context.Phase)) end

            InactivityTime = getTime() + SEND_TIMEOUT
            Waiting_RX = 0 -- Switch to Send mode to send heartbeat

            if context.Phase == PHASE.EXIT then -- Did not receive response to Exit_Request
                DSM_ReleaseConnection()
            end

            if context.Phase ~= PHASE.RX_VERSION and context.Phase ~= PHASE.VALUE_CHANGING_WAIT and
                context.Phase ~= PHASE.WAIT_CMD then
                -- Only change to WAIT_CMD if we are NOT already waiting for Data
                context.Phase = PHASE.WAIT_CMD
                context.Refresh_Display = true
            end

            if context.Phase == PHASE.RX_VERSION then
                -- Refresh screen again
                context.Refresh_Display = true
            end

            
        end
    end
end

local function load_msg_from_file(fileName, mem, Text, List_Text, List_Text_Img, RxName, Flight_Mode)
    local function rtrim(s)
      local n = string.len(s)
      while n > 0 and string.find(s, "^%s", n) do n = n - 1 end
      return string.sub(s, 1, n)
    end
  
    --print(string.format("Loading messages from [%s]",fileName))
    local dataFile = io.open(fileName, "r")   -- read File
    -- cannot read file???
    assert(dataFile, "Cannot load Message file:" .. fileName)
  
    local data = io.read(dataFile, mem * 1024) -- read up to 10k characters (newline char also counts!)
    io.close(dataFile)
  
    collectgarbage("collect")
  
    local lineNo = 0
    for line in string.gmatch(data, "[^\r\n]+") do
      lineNo = lineNo + 1
      --print(string.format("Line [%d]: %s",lineNo,line))
  
      -- Remove Comments
      local s = string.find(line, "--", 1, true)
      if (s ~= nil) then
        line = string.sub(line, 1, s - 1)
      end
  
      line = rtrim(line)
  
      if (string.len(line) > 0) then
        local a, b, c = string.match(line, "%s*(%a*)%s*|%s*(%w*)%s*|(.*)%s*")
        --print(string.format("[%s] [%s] [%s]",a,b,c))
        if (a ~= nil) then
          local index = tonumber(b)
  
          if (index == nil) then
            assert(false, string.format("%s:%d: Invalid Hex num [%s]", fileName, lineNo, b))
          elseif (a == "T") then
            Text[index] = c
          elseif (a == "LT") then
            List_Text[index] = c
          elseif (a == "LI") then
            List_Text_Img[index] = c
          elseif (a == "FM") then
            Flight_Mode[0] = c
          elseif (a == "RX") then
            RxName[index] = c
          else
            assert(false, string.format("%s:%d: Invalid Line Type [%s]", fileName, lineNo, a))
          end
        end
      end
      if (lineNo % 50 == 0) then
        collectgarbage("collect")
      end
    end -- For
  
    --print(string.format("Loaded [%d] messages",lineNo))
    data = nil
  end


-- Init
local function DSM_Init(toolName)
    local dateTime = getDateTime()
    local dateStr = dateTime.year.."-"..dateTime.mon.."-"..dateTime.day.."   "..dateTime.hour..":"..dateTime.min

    local ver, radio, maj, minor, rev, osname = getVersion()

    if (DEBUG_ON) then 
        LOG_write("---------------DSM New Session %s ----------------\n", toolName, dateStr)
        LOG_write("Radio Info:    %s\n", radio .. " " .. (osname or "OpenTx") .. "  " .. ver) 
        LOG_write("Date      :    %s\n", dateStr) 
        LOG_write("DsmLib Version :    %s\n", LIB_VERSION) 
    end

    DSM_Context.Phase = PHASE.RX_VERSION

    -- Phase Names
    PhaseText[PHASE.RX_VERSION]          = "RX_VERSION"
    PhaseText[PHASE.WAIT_CMD]            = "WAIT_CMD"
    PhaseText[PHASE.MENU_TITLE]          = "MENU_TITLE"
    PhaseText[PHASE.MENU_REQ_TX_INFO]    = "MENU_REQ_TX_INFO"
    PhaseText[PHASE.MENU_LINES]          = "MENU_LINES"
    PhaseText[PHASE.MENU_VALUES]         = "MENU_VALUES"
    PhaseText[PHASE.VALUE_CHANGING]      = "VALUE_CHANGING"
    PhaseText[PHASE.VALUE_CHANGING_WAIT] = "VALUE_CHANGING_WAIT"
    PhaseText[PHASE.VALUE_CHANGE_END]    = "VALUE_CHANGE_END"
    PhaseText[PHASE.EXIT]                = "EXIT"
    PhaseText[PHASE.EXIT_DONE]           = "EXIT_DONE"


    -- Line Types
    LineTypeText[LINE_TYPE.MENU]            = "M"
    LineTypeText[LINE_TYPE.LIST_MENU_NC]    = "LM_nc"
    LineTypeText[LINE_TYPE.LIST_MENU]       = "LM"
    LineTypeText[LINE_TYPE.LIST_MENU_TOG]   = "LM_tog"
    LineTypeText[LINE_TYPE.VALUE_NUM_I8_NC] = "V_nc"
    LineTypeText[LINE_TYPE.VALUE_PERCENT]   = "V_%"
    LineTypeText[LINE_TYPE.VALUE_DEGREES]   = "V_de"
    LineTypeText[LINE_TYPE.VALUE_NUM_I8]    = "V_i8"
    LineTypeText[LINE_TYPE.VALUE_NUM_I16]   = "V_i16"
    LineTypeText[LINE_TYPE.VALUE_NUM_SI16]  = "V_s16"
    LineTypeText[LINE_TYPE.LT_EMPTY]        = "Z"

    DSM_ReadTxModelData()

    -- Load  messages from external file (/DSMLIB/msg_en.txt)
    load_msg_from_file(MSG_FILE,10,Text,List_Text,List_Text_Img,RxName,Flight_Mode)
end


local function DSM_Init_Text(rxId)
    --Text to be displayed
    -- For menu lines who are not navigation to other menus (SubHeders or Plain text)
    -- you can use some formatting options AT THE END OF THE STRING :

    -- Text allightment:  /c = CENTER, /r = RIGHT
    -- Text effects:  /b = BOLD
    -- Text formatting: /p = PERCENT numbers (forced if not in Line Type=PERCENT)
    -- Navigaton: /m = Force to be a Menu button, when a menu navigates to itself, 
    --      is usually a message line.. but sometimes, we want to navigate to the same page to refresh values

    -- array List_Values:
    -- For some Menu LIST VALUES, special Lines of type:LIST_MENU1, the valur options seems not
    -- to be contiguos,  the array "Menu_List_Values" can help narrow down the 
    -- valid menu options. I think this should come from the RX, but cant find where.
    -- Most of the times, Limes of type LIST_MENU1 comes with a 0->244 value range that is not correct
    -- usually is Ihnibit + range of contiguos values, but cant seems to find in the RX data receive the values 
    -- to do it automatically

    local function getTxChText(ch)
        return " ("..(MODEL.TX_CH_TEXT[ch] or "--")..")"
    end

    -- OVERRIDES for list of valid VALUES and channel names 

    -- Channel selection for SAFE MODE and GAINS on  FC6250HX
    -- List_Text[0x000C] = "Inhibit?" --?
    for i = 0, 7 do List_Text[0x000D + i] = "Ch"..(i+5) ..getTxChText(i+4) end -- Aux channels (Ch5 and Greater)

    -- Servo Output values.. 
    local servoOutputValues =  {0x0003,0x002D,0x002E,0x002F}  --Inh (GAP), 5.5ms, 11ms, 22ms. Fixing L_m1 with 0..244 range!
    --List_Text[0x002D] = "5.5ms"
    --List_Text[0x002E] = "11ms"
    --List_Text[0x002F] = "22ms"

    -- Gain Values
    local gainValues = {0x0032,0x0033,0x0034}  -- 1X, 2X, 4X   -- Fixing L_m1 with 0..244 range!
    --List_Text[0x0032] = "1 X"
    --List_Text[0x0033] = "2 X"
    --List_Text[0x0034] = "4 X"

    -- List of Channels for Safe, Gains, Panic, except FC6250HX that uses other range (0x00C..0x015)
    -- the valid range Starts with GEAR if enabled  (Thr,Ail,Ele,Rud are not valid, the RX reject them ) 
    -- Valid Values: Inhibit? (GAP), Gear,Aux1..Aux7,X-Plus-1..XPlus-8
    local channelValues = {0x0035,0x003A,0x003B,0x003C,0x003D,0x003E,0x003F,0x0040,0x0041,0x0042,0x0043,0x0044,0x0045,0x0046,0x0047,0x0048,0x0049} 
    
    --List_Text[0x0035] = "Inhibit?" 
    for i = 0, 11 do List_Text[0x0036 + i] = "Ch"..(i+1) .. getTxChText(i) end -- Channels on  AR637T

    for i = 1, 8 do -- 41..49
        List_Text[0x0041 + i] = "Ch"..(i+13)
    end

    -- ****No longer overrides of previous XPlus values, since using different array
    -- for List_Text values

    if (rxId ~= RX.FC6250HX) then  -- Restrictions for non FC6250HX
        List_Values[0x0051]=servoOutputValues
        List_Values[0x0052]=servoOutputValues
        List_Values[0x0053]=servoOutputValues
        List_Values[0x0054]=servoOutputValues
        List_Values[0x0055]=servoOutputValues
        List_Values[0x0056]=servoOutputValues
    end

    -- Flight mode channel selection
    --Text[0x0078] = "FM Channel"
    if (rxId ~= RX.FC6250HX) then List_Values[0x0078]=channelValues end --FC6250HX uses other range

    -- Gain  channel selection
    --Text[0x0089] = "Gain Channel"
    if (rxId ~= RX.FC6250HX) then List_Values[0x0089]=channelValues end --FC6250HX uses other range

    -- Gain Sensitivity selection
    --Text[0x008A] = "Gain Sensitivity/r";  
    List_Values[0x008A]=gainValues  -- Right Alight, (L_M1 was wide open range 0->244)

    -- Safe mode options, Ihnibit + this values 
    local safeModeOptions = {0x0003,0x00B0,0x00B1}  -- inh (gap), "Self-Level/Angle Dem, Envelope
    --List_Text[0x00B0] = "Self-Level/Angle Dem"
    --List_Text[0x00B1] = "Envelope"

    --FC6250HX
    --Text[0x00D2] = "Panic Channel" 
    if (rxId ~= RX.FC6250HX) then List_Values[0x00D2]=channelValues end --FC6250HX uses other range

    --Inh, Self-Level/Angle Dem, Envelope -- (L_M was wide open range 0->244)
    --Text[0x01F8] = "Safe Mode";    
    List_Values[0x01F8]=safeModeOptions 
end

-- Adjust the displayed value for Flight mode line as needed
local function GetFlightModeValue(line)
    local value =  line.Val or 0     -- protect when in the middle of changing FM can be nil
    local textId = line.TextId
    local header = line.Text 
    local out = value .. ""

    if (textId == 0x8000) then  -- FC6250HX
        if (DSM_Context.RX.Id == RX.FC6250HX) then
            -- Helicopter Flights modes 
            if (value==0)     then out = header .. "  1 / Normal 1" 
            elseif (value==1) then out = header .. "  2 / Normal 2" 
            elseif (value==2) then out = header .. "  3 / Stunt 1" 
            elseif (value==3) then out = header .. "  4 / Stunt 2" 
            elseif (value==4) then out = header .. "  5 / Hold" 
            else
                out = header .. " " .. value
            end
        else
            -- No adjustment needed
            out = header .. " " .. (value + 1)
        end
    elseif (textId == 0x8001) then -- AR630-637, AR8360T, AR10360T
        -- Seems that we really have to add +1 to the value, so Flight Mode 0 is Really Flight Mode 1
        out = header .. " " .. (value + 1)
    else
        -- Default, return the value as we Have it 
        out = header .. " " .. (value + 1)
    end
    return out
end

------------------------------------------------------------------------------------------------------------
-- Lib EXPORTS

-- Export Constants
Lib.PHASE       = PHASE
Lib.LINE_TYPE   = LINE_TYPE
Lib.RX          = RX
Lib.DISP_ATTR   = DISP_ATTR
Lib.CH_TYPE     = CH_TYPE

Lib.BACK_BUTTON = BACK_BUTTON
Lib.NEXT_BUTTON = NEXT_BUTTON
Lib.PREV_BUTTON = PREV_BUTTON
Lib.MAX_MENU_LINES = MAX_MENU_LINES

-- Export Shared Context Variables
Lib.DSM_Context = DSM_Context
Lib.MODEL = MODEL

-- Export Functions
Lib.LOG_write = LOG_write
Lib.LOG_close = LOG_close
Lib.getElapsedTime = getElapsedTime
Lib.Get_Text = Get_Text
Lib.Get_List_Text = Get_List_Text
Lib.Get_List_Text_Img = Get_List_Text_Img

Lib.phase2String = phase2String
Lib.lineValue2String = lineValue2String
Lib.menu2String = menu2String
Lib.menuLine2String = menuLine2String
Lib.channelType2String = channelType2String

Lib.isSelectableLine = isSelectableLine
Lib.isEditableLine = isEditableLine
Lib.isListLine = isListLine
Lib.isPercentValueLine = isPercentValueLine
Lib.isPercentValueLineByMinMax = isPercentValueLineByMinMax
Lib.isNumberValueLine = isNumberValueLine
Lib.isDisplayAttr = isDisplayAttr
Lib.isFlightModeLine = isFlightModeLine
Lib.GetFlightModeValue = GetFlightModeValue

Lib.StartConnection = DSM_StartConnection
Lib.ReleaseConnection = DSM_ReleaseConnection
Lib.ChangePhase = DSM_ChangePhase
Lib.MenuPostProcessing = DSM_MenuPostProcessing
Lib.MenuLinePostProcessing = DSM_MenuLinePostProcessing
Lib.Value_Add = DSM_Value_Add
Lib.Value_Default = DSM_Value_Default
Lib.Value_Write_Validate = DSM_Value_Write_Validate
Lib.GotoMenu = DSM_GotoMenu
Lib.MoveSelectionLine = DSM_MoveSelectionLine
Lib.Send_Receive = DSM_Send_Receive
Lib.Init = DSM_Init
Lib.Init_Text = DSM_Init_Text

Lib.SetDSMChannelInfo = DSM_SetDSMChannelInfo
Lib.Get_RxName = Get_RxName

return Lib
