#airton protocol from me and brice (pingus.org)
#todo : implement quiet mode on the fan mode
#todo : check boost mode on the fan mode
#todo : publish autodiscovery for homeassistant
# crc snippet from  https://github.com/peepshow-21/ns-flash/blob/master/berry/nxpanel.be

import string
import mqtt
import persist
import introspect

var topicprefix = "cmnd/Newclim/"
var FeedbackTopicPrefix = "tele/Newclim/"
var FanSpeedSetpoint 
var OscillationModeSetpoint
var TemperatureSetpoint
var ACmode
var incomingpayload = bytes()
var externaltemptopic = "nodered/temp-salon"
var internalThermostat = 1 							#1=enables the small hysteresis logic in the code  0 to let the AC unit drive its regulation
var TemperatureSetpointToACunit

TemperatureSetpointOffset = 8
# serial communications (pin 26 TX , PIN 32 RX)
ser = serial(32, 26, 9600, serial.SERIAL_8N1)

#an internal simple thermostat  returns 0 while the unit should stop and 1 while it should start
var last_thermostat_state
def thermostat(Setpoint,ActualTemp)
    var delta
	var hyst = 0.3
	if ACmode == "heat"
		delta = ActualTemp - Setpoint
	elif ACmode == "cool"
		delta = Setpoint - ActualTemp
	else
		delta = 0.0
	end
	print("function thermostat : setpoint=", Setpoint , " delta=", delta," last_thermostat_state=",last_thermostat_state)
	if (delta > hyst ) && last_thermostat_state!= 0
		print("function thermostat : delta > hyst")
		last_thermostat_state = 0
		print("function thermostat : last_thermostat_state=",last_thermostat_state)
		return 0

	elif (delta < -hyst ) && last_thermostat_state!= 1
		print("function thermostat  : delta < -hyst ")
		last_thermostat_state = 1
		print("function thermostat : last_thermostat_state=",last_thermostat_state)
		return 1

	end

end
# used to write to flash only if values differs , storageplace is a string
def StoreIfDifferent(ValueToCompare,StoragePlace)
	if number(introspect.get(persist, StoragePlace)) == ValueToCompare
		print("function StoreIfDifferent : nothing to store")
		return
	else 
		introspect.set(persist, StoragePlace,ValueToCompare)
		print("function StoreIfDifferent : storing the value :",ValueToCompare, "to persist.",StoragePlace)
	end
end

#modbus CRC16
def modcrc16(data, poly)	
	if !poly  poly = 0xA001 end
		# CRC-16 MODBUS HASHING ALGORITHM
		var crc = 0xFFFF
		for i:0..size(data)-1
			crc = crc ^ data[i]
				for j:0..7
					if crc & 1
						crc = (crc >> 1) ^ poly
					else
						crc = crc >> 1
				end
		end
	end
	return crc
end

#checking messages incoming from AC unit CRCet
def CheckMessage(payload)
   #print(payload.size()) #debug
   var MsgCalCrc = modcrc16(payload[0..payload.size()-3])
   var MsgCrc = payload.get(payload.size()-2,-2) # last -2 param means endianness swap
   #print("calculated message = " , MsgCalCrc , "crc of payload = ", MsgCrc) #debug
   if MsgCalCrc == MsgCalCrc
	 return 1
   else
	 return 0
   end
end






#retrieve the AC unit mode from the AC unit frame	
def GetACmode(payload) # available modes are : "auto","cool","dry","fan_only","heat"
	var ACmodelist = ["auto","cool","dry","fan_only","heat","off",]
	var ACmodeString = "auto"
	var AConOffState = 0
	#print("byte 13 : 0x" ,string.hex(payload[13]), " ACmode 3 bits value :", payload.getbits(106,1), payload.getbits(105,1), payload.getbits(104,1), " AC unit on/off state :", payload.getbits(107,1) ) #debug
	AConOffState = payload.getbits(107,1)
	if AConOffState == 1 
	ACmodeString = ACmodelist[payload.getbits(104,3)]
	else
	ACmodeString = ACmodelist[5]    
	end
	print("function GetACmode :  ACmodeString = " , ACmodeString ) #debug
	return ACmodeString
end

#retrieve the AC fan speed from the AC unit frame
def GetFanSpeed(payload)
	var TurboModeState = 0
	var FanModeString = "auto"
	var FanModeList = ["auto","low","low-medium","medium","medium-high","high","stepless","turbo"]
	#print("byte 13 : 0x" ,string.hex(payload[13]), " FanSpeedMode 3 bits value :", payload.getbits(110,1), payload.getbits(109,1), payload.getbits(108,1), " mode turbo :", payload.getbits(111,1) ) #debug
	if TurboModeState == 0
	FanModeString = FanModeList[payload.getbits(108,3)]
	else
	FanModeString = FanModeList[7]
	end
	print( "function GetFanSpeed : FanModeString = " , FanModeString)
	return FanModeString
end

#retrieve the AC oscillation mode from the AC unit frame
def GetOscillationMode(payload)
	var OscillationModeList = ["off", "on" ,"high","medium-high","medium","medium-low","low","sweep 3-5","sweep 3-5","sweep 2-5","sweep2-4","sweep1-4","sweep 1-3","sweep 4-6"]
	#print("function GetOscillationMode : byte 15 : 0x" ,string.hex(payload[15]), " Oscillation mode up/down 4 bits value :",payload.getbits(123,1), payload.getbits(122,1), payload.getbits(121,1), payload.getbits(120,1)) #debug
	var OscillationModeString = OscillationModeList[payload.getbits(120,4)]
	print ("function GetOscillationMode : OscillationModeString = ", OscillationModeString)
	return OscillationModeString
end

#retrieve the AC internal unit temperature sensor value from the AC unit frame
def GetInternalTemperature(payload)
	var temperature = 0
	#print("byte 10 , ambient temperature integer part : " , payload.get(10,1) , "byte 11, ambient temperature decimal part: " , payload.get(11,1)   ) #debug
	temperature = real(payload.get(10,1)) + real(payload.get(11,1)) /10
	print("function GetInternalTemperature : internal unit temperature: ", temperature)
	return temperature
end

#retrieve the AC setpoint temperature
def GetTemperatureSetpoint(payload)
	#print("byte 14 , setpoint temperature: " ,payload.getbits(115,1),payload.getbits(114,1), payload.getbits(113,1), payload.getbits(112,1) ) #debug
	if internalThermostat == 0
		TemperatureSetpoint = payload.getbits(112,4) +16
		StoreIfDifferent(TemperatureSetpoint,"TempSetpoint")
		print("function GetTemperatureSetpoint : TemperatureSetpoint retrieved on payload from ACunit : ", TemperatureSetpoint)
	# will directly return the setpoint received by mqtt
	#there is a catch here , this function has to be reworked in order to ensure a good sync while using infrared remote
	else
		TemperatureSetpoint = number(persist.TempSetpoint)
		print("function GetTemperatureSetpoint : TemperatureSetpoint retrieved from persistent memory : ", TemperatureSetpoint)
	end
	return TemperatureSetpoint
end
	
def PublishFeedback(payload)
	var MyACmode = GetACmode(payload)
	var MyFanSpeed = GetFanSpeed(payload)
	var MyOscillationMode = GetOscillationMode(payload)
	
	# sending back the temperature setpoint value minus the offset for the regulation to happen correctly
	var MyTemperature = str(GetInternalTemperature(payload) )
	if internalThermostat == 0
	  TemperatureSetpoint = GetTemperatureSetpoint(payload) - TemperatureSetpointOffset
	else 
	  TemperatureSetpoint = GetTemperatureSetpoint(payload)
	end
	#initialize sttings value with first feedback from AC unit to manage restart conditions
	if FanSpeedSetpoint == nil FanSpeedSetpoint = MyFanSpeed  print("recovered FanSpeedSetpoint : " , FanSpeedSetpoint) end
	if OscillationModeSetpoint == nil OscillationModeSetpoint = MyOscillationMode print("recovered OscillationModeSetpoint : ", OscillationModeSetpoint) end
	if TemperatureSetpoint == nil print("no TemperatureSetpoint available, check persistance file value :", TemperatureSetpoint) end
	if ACmode == nil ACmode = MyACmode print("recovered ACmode : ", ACmode) end
	
	
	print("function PublishFeedback : got all needed value, publishing in mqtt topics")
	mqtt.publish(FeedbackTopicPrefix + "mode/get" , MyACmode)
	#print("function PublishFeedback : published FanSpeedFeedback")
	mqtt.publish(FeedbackTopicPrefix + "fan/get" , MyFanSpeed)
	#print("function PublishFeedback : published FanSpeedFeedback")
	mqtt.publish(FeedbackTopicPrefix + "swing/get" , MyOscillationMode)
	#print("function PublishFeedback : published OscillationModeFeedback")
	mqtt.publish(FeedbackTopicPrefix + "Actualtemp/get" , MyTemperature)
	#print("function PublishFeedback : published TemperatureFeedback")
	mqtt.publish(FeedbackTopicPrefix + "Actualsetpoint/get" , str(TemperatureSetpoint))
	#print("function PublishFeedback : published Temperature_setpointFeedback")
	
end
	
def GetFrametype(payload)
	var FrameTypeString = "NONE" #frame A3 = feedback from AC unit to wifi module
	if CheckMessage(payload) == 1
		#print("function GetFrametype : frame CRC seems valid")
		if payload.size() == 34
			#print("function GetFrametype : seeking frame type on byte 7 : 0x" ,string.hex(payload[7]) ) #debug
			
			if string.hex(payload[7]) == "A3"
				#print("function GetFrametype : frame type is A3 : AC unit is giving back useful feedback")
				print("function GetFrametype : valid message from AC unit :", payload.tostring(60))
				FrameTypeString = "ACFeedback"
				PublishFeedback(payload)
				return FrameTypeString
			else 
				#print("function GetFrametype : frame is 34 bytes long but is not A3 type")
				return "INVALID_FRAME"
			end	
		else
			#print("function GetFrametype : frame is not 34 bytes legnth")
		end
		
	else	
		#print("function GetFrametype : CRC seems invalid, incomplete buffer ?")
		return "BADCRC"
	end	
	
end	

	
def forgepayload(Acmode,FanSpeed,OscillationMode,TemperatureSP)
	var frame = bytes("7A7A21D5180000A100000000" + "00000000" + "000000000000")
	#print("function forgepayload : empty frame= " ,frame)
	var ACmodeValues = {"auto": 0x00 , "cool" : 0x01 , "dry" : 0x02 , "fan_only" : 0x03 , "heat": 0x04 , "off" : 0x08}
	var FanModeValues = {"auto" : 0x00 ,"low" : 0x10 , "low-medium" : 0x20 ,"medium" : 0x30 , "medium-high" : 0x40 , "high" : 0x50 ,"stepless" : 0x60  ,"turbo" : 0x70 }
	var OscillationModeValues = {"off" : 0x00 , "on" : 0x01 ,"high" : 0x02 ,"medium-high" : 0x03 ,"medium" : 0x04 ,"medium-low" : 0x05 ,"low" : 0x06 ,"sweep 1-5" : 0x07 ,"sweep 2-5" : 0x08 ,"sweep2-4" : 0x09 ,"sweep1-4" : 0x0A ,"sweep 1-3" : 0x0B ,"sweep 4-6" : 0x0C ,"sweep 3-5": 0X0D}

	#setting ACmode on register 12 of the frame
	var Reg12 = 0x00
	var Reg13 = 0x00
	var Reg14 = 0x00
	var Reg15 = 0x98 #0101 0000 0x50 #config word 1001 1000 0x00
	#Config Word : 
	#Bit
	#Bit 15 : light on:off	 	0x80 1000 0000 0x00 (tuya 0x08 )
	#Bit 14 : ionizer on/off 	0x70 0100 0000 0x00
	#Bit 12 : ??		 	0x10 0001 0000 0x00
	#Bit 11 : sound on not tested?? 0X08 0000 1000 0x00 (tuya 0x0010 not match :-( )
	#Bit 9 : sleep mode	 	0x02 0000 0010 0x00
	

	if Acmode != "off"
		Reg12= ACmodeValues[Acmode] | 0x08
	elif Acmode == "off"
		Reg12=  0x00
	end	
	
	#setting FanSpeed on register 12 of the frame
	if Acmode != "turbo"
		Reg12 = Reg12 |	FanModeValues[FanSpeed]
	elif Acmode == "turbo" #todo , check if its worth it to separate turbo mode
		Reg12 = Reg12 |	FanModeValues[FanSpeed]
	end	
	
	#setting swing mode (oscillation ouf louvres ) on register 14 of the frame
	Reg14 = Reg14 |	OscillationModeValues[OscillationMode]
	
	#setting temperature setpoint on register 13
	Reg13 = number(TemperatureSP) - 16
	print("function forgepayload : Register 13 ,temperature setpoint -16 : "  , Reg13)
				
	#print("function forgepayload : register 12 , AC mode and fanspeed :", string.hex(Reg12))
	#print("function forgepayload : register 13 , temperature setpoint :", string.hex(Reg13))
	#print("function forgepayload : register 14 , OscillationMode      :", string.hex(Reg14))
	#print("function forgepayload : register 15 , ConfigWord (todo)    :", string.hex(Reg15))
	#setting all the calculated parameters into the frame		
	frame.set(12,Reg12)
	frame.set(13,Reg13)
	frame.set(14,Reg14)
	frame.set(15,Reg15)	
	#print("function forgepayload : filled frame= " ,frame)
	
	#appending CRC
	modcrc16(frame)
	#print("function forgepayload : ", modcrc16(frame))
	frame.add(modcrc16(frame),-2)
	#print("function forgepayload : filled frame with crc = " ,frame)
	return frame
end

def MQTTSubscribeDispatcher(topic, idx, payload_s, payload_b)
  var frametosend
  print("function MQTTSubscribeDispatcher : message received from mqtt")
  print("function MQTTSubscribeDispatcher : actual ACmode = ", ACmode)
  print("function MQTTSubscribeDispatcher : actual FanSpeedSetpoint = ", FanSpeedSetpoint)
  print("function MQTTSubscribeDispatcher : actual OscillationModeSetpoint = ", OscillationModeSetpoint)
  print("function MQTTSubscribeDispatcher : actual TemperatureSetpoint = ", TemperatureSetpoint)
  # ensure we received a fisrt feedback from the AC unit 
  if ACmode == nil || FanSpeedSetpoint == nil || OscillationModeSetpoint == nil || TemperatureSetpoint == nil
    print("function MQTTSubscribeDispatcher : Some of the variables are not yet received , escaping")
	
	return
  end 
  #we send back gratuitous feedback upon reception to ensure homeassistant gets immediate feedback and sets correctly its values (why doesnt Homeassistant have time setting for the feedback ? )
  if topic == (topicprefix + "mode/set")
	ACmode = payload_s
	print("function MQTTSubscribeDispatcher : received ACmode = ", ACmode)
	mqtt.publish(FeedbackTopicPrefix + "mode/get" , ACmode)
	print("function MQTTSubscribeDispatcher : publishing immediately ACmode")
	
  elif topic == (topicprefix + "fan/set")
	FanSpeedSetpoint = payload_s
	print("function MQTTSubscribeDispatcher : received FanSpeedSetpoint = ", FanSpeedSetpoint)
	mqtt.publish(FeedbackTopicPrefix + "fan/get" , FanSpeedSetpoint)
	print("function MQTTSubscribeDispatcher : publishing immediately FanSpeedSetpoint")
	
  elif topic == (topicprefix + "swing/set")
	OscillationModeSetpoint = payload_s
	print("function MQTTSubscribeDispatcher : received OscillationModeSetpoint = ", OscillationModeSetpoint)
	mqtt.publish(FeedbackTopicPrefix + "swing/get" , OscillationModeSetpoint)
	print("function MQTTSubscribeDispatcher : publishing immediately OscillationModeSetpoint")
  
  elif topic == (topicprefix + "temperature/set")
	#some offset trials , the feedback is the temperature without the offset
	print("function MQTTSubscribeDispatcher : received TemperatureSetpoint = ", number(payload_s))
	if ACmode == "heat" && internalThermostat == 0
		TemperatureSetpoint = number(payload_s) + TemperatureSetpointOffset
		print("function MQTTSubscribeDispatcher : heating mode, applying positive offset of :" , TemperatureSetpointOffset , "°C")
	
	elif ACmode == "heat" && internalThermostat == 1
		TemperatureSetpoint = number(payload_s)
		print("function MQTTSubscribeDispatcher : internal_thermostat enabled in heat mode : saving the setpoint",TemperatureSetpoint , " to persistance file if different then previously")
		StoreIfDifferent(TemperatureSetpoint,"TempSetpoint")

	elif ACmode == "cool" && internalThermostat == 0
		TemperatureSetpoint = number(payload_s) - TemperatureSetpointOffset
		print("function MQTTSubscribeDispatcher : cooling mode, applying negative offset of :" , TemperatureSetpointOffset , "°C")

	elif ACmode == "cool" && internalThermostat == 1
		TemperatureSetpoint = number(payload_s)
		print("function MQTTSubscribeDispatcher : internal_thermostat enabled in cool mode: saving the setpoint:",TemperatureSetpoint , " to persistance file if different then previously") 
		StoreIfDifferent(TemperatureSetpoint,"TempSetpoint")

	else

	end
	print("function MQTTSubscribeDispatcher : publishing immediately TemperatureSetpoint")
	mqtt.publish(FeedbackTopicPrefix + "Actualsetpoint/get" , payload_s)
	
   
  #on external temperature reception, we trigger the thermostat, we dont
  #stop the unit but give :
  # a  lower temperature setpoint (17°C) while in heat mode
  # a higher temperature setpoint (31°c) while in cool mode 
  #to force the AC unit 
  #to pause with louvre open
  elif topic == externaltemptopic && internalThermostat == 1 
	print("function MQTTSubscribeDispatcher : received a temperature value from external thermometer : ", number(payload_s) )
	var thermostat_state = thermostat(TemperatureSetpoint,number(payload_s))
	print("function MQTTSubscribeDispatcher : thermostat_state : " ,thermostat_state)
	if thermostat_state == nil
		return
	elif thermostat_state
		if   ACmode == "heat"
			TemperatureSetpointToACunit = 31
		elif ACmode == "cool"
			TemperatureSetpointToACunit = 17
		end
	else
		if   ACmode == "heat"
			TemperatureSetpointToACunit = 17
		elif ACmode == "cool"
			TemperatureSetpointToACunit = 31
		end
	StoreIfDifferent(TemperatureSetpointToACunit , "TemperatureSetpointToACunit")
	end
	
	print("function MQTTSubscribeDispatcher : thermostat function returned 1 , sending frame with",TemperatureSetpointToACunit,"°C to AC unit")
	
	frametosend = forgepayload(ACmode,FanSpeedSetpoint,OscillationModeSetpoint,TemperatureSetpointToACunit)
	ser.write(frametosend)
  	return
  end
  
  # in thermostat mode we send back the external setpoint #
  if internalThermostat == 1
	frametosend = forgepayload(ACmode, FanSpeedSetpoint, OscillationModeSetpoint, TemperatureSetpointToACunit)
  else
    frametosend = forgepayload(ACmode, FanSpeedSetpoint, OscillationModeSetpoint, int(TemperatureSetpoint))
  end

  print("function MQTTSubscribeDispatcher : sending frame to AC unit: ", frametosend)
  ser.write(frametosend)
  return true
end

# avail variable contains the nr of char present in the serial buffer
def getfromserial()
	var avail = ser.available()
	if avail != 0
	    var msg = ser.read()
	    ser.flush()
	    if msg[0..1] == bytes("7A7A") && avail == msg.get(4,1)
			#print("function GetFromSerial : buffer filled with :", avail , " bytes")
			#print ("function GetFromSerial : message length :", msg.get(4,1))
			#print("function GetFromSerial : message from AC unit :", msg.tostring(60))
		
		elif msg[0..1] == bytes("7A7A") && avail > msg.get(4,1)
			#print ("function GetFromSerial : buffer is bigger than frame, cutting frame")
			var msg2 = msg[msg.get(4,1)..size(msg)-1]
			msg = msg[0..msg.get(4,1)-1]
			#print("function GetFromSerial : message from AC unit :", msg.tostring(60))
			#print("function GetFromSerial : remaining msg   :", msg2.tostring(60)) #todo , implement a buffer of frames.
		end
		#print("function GetFromSerial : calling GetFrametype(msg)")
		GetFrametype(msg)
	else 
	#	print ("function GetFromSerial : nothing in the buffer")
	end
end

######### main program ########

print("starting program : mqtt topics", topicprefix , FeedbackTopicPrefix )
mqtt.subscribe(topicprefix + "mode/set",MQTTSubscribeDispatcher)
mqtt.subscribe(topicprefix + "fan/set",MQTTSubscribeDispatcher)
mqtt.subscribe(topicprefix + "swing/set",MQTTSubscribeDispatcher)
mqtt.subscribe(topicprefix + "temperature/set",MQTTSubscribeDispatcher)
mqtt.subscribe("testsclim/payloadfromclim",MQTTSubscribeDispatcher)
mqtt.subscribe(externaltemptopic,MQTTSubscribeDispatcher)

#check if any temperature setpoint has been saved to flash
if persist.member("TempSetpoint") != nil
	print("persistance : retrieving temperature setpoint from tasmota flash")
	TemperatureSetpoint = number(persist.member("TempSetpoint"))
else
	print("persistance : setting a default temperature setpoint")
	TemperatureSetpoint = 20
	persist.TempSetpoint = TemperatureSetpoint
end

if persist.member("TemperatureSetpointToACunit") != nil
	print("persistance : retrieving TemperatureSetpointToACunit from tasmota flash")
	TemperatureSetpointToACunit = number(persist.member("TemperatureSetpointToACunit"))
else
	print("persistance : setting a default TemperatureSetpointToACunit")
	TemperatureSetpointToACunit = 17
	persist.TemperatureSetpointToACunit = TemperatureSetpointToACunit
end

def loopme()
  getfromserial()
  tasmota.set_timer(200, loopme, 1)
end
loopme()

