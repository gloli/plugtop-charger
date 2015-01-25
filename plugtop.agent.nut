// Twilio specifics for texting
const TWILIO_URL = "https://api.twilio.com/2010-04-01";
const TWILIO_SID = "AC026c50ec54694ee238be87d0235b0bc9";
const TWILIO_AUTH = "fdc79c638bced48e2da4c28b182f909d";
const TWILIO_NUM = "+16466814341";  // twilio number, send sms
const PERS_NUM = "+16462588347";    // personal, receive sms

// device types
const LT = "laptop";
const TA = "tablet";
const PH = "phone";

// device ranges
const NONE_P = 0;
const NONE_PA = 90;
const LT_UNCHARGED_P = 50;
const LT_UNCHARGED_PA = 20;
const LT_CHARGED_P = 20;
const LT_CHARGED_PA = 65;
const T_UNCHARGED_P = 10;
const T_UNCHARGED_PA = 20;
const T_CHARGED_P = 5;
const T_CHARGED_PA = 70;
const P_UNCHARGED_P = 10;
const P_UNCHARGED_PA = 50;
const P_CHARGED_P = 0;
const P_CHARGED_PA = 90;

class Twilio {
    
    _accountSid = null;
    _authToken = null;
    _phoneNumber = null;
    
    constructor(accountSid, authToken, phoneNumber) {
        _accountSid = accountSid;
        _authToken = authToken;
        _phoneNumber = phoneNumber;
    }
    
    function sendsms(to, message, callback = null) {
        local url = TWILIO_URL+"/Accounts/"+TWILIO_SID+"/Messages.json"
        
        local auth = http.base64encode(_accountSid + ":" + _authToken);
        local headers = { "Authorization": "Basic " + auth };
        
        local body = http.urlencode({
            From = _phoneNumber,
            To = to,
            Body = message
        });
        
        local request = http.post(url, headers, body);
        if (callback == null) return request.sendsync();
        else request.sendasync(callback);
    }
    
    function respondsms(resp, message) {
        local data = { Response = { Message = message } };
        local body = xmlEncode(data);
        
        resp.header("Content-Type", "text/xml");
        
        
        server.log(body);
        
        resp.send(200, body);
    }
    
    function xmlEncode(data, version="1.0", encoding="UTF-8") {
        return format("<?xml version=\"%s\" encoding=\"%s\" ?>%s", version, encoding, _recursiveEncode(data))
    }
    
    /******************** Private Function (DO NOT CALL) ********************/
    function _recursiveEncode(data) {
        local s = "";
        foreach(k, v in data) {
            if (typeof(v) == "table" || typeof(v) == "array") {
                s += format("<%s>%s</%s>", k.tostring(), _recursiveEncode(v), k.tostring());
            } 
            else { 
                s += format("<%s>%s</%s>", k.tostring(), v.tostring(), k.tostring());;
            }
        }
        return s
    }
    
}

type <- "";

// get type
function checkDevice(sample) {
    if (sample.power >= LT_UNCHARGED_P && sample.phase_angle <= LT_UNCHARGED_PA) 
        type <- LT;
    if ((sample.power > P_UNCHARGED_P&&sample.power < T_UNCHARGED_P) && sample.phase_angle > T_UNCHARGED_PA) 
        type <- TA;
    if (sample.power <= P_UNCHARGED_P && sample.phase_angle >= P_UNCHARGED_PA) 
        type <- PH;
    
}

// stats correspond to full battery
function checkFull(sample, type) {
    // device unplugged
    if  (sample.power == NONE_P && sample.phase_angle == NONE_PA)
        return true;
        
    switch (type) {
    case PH:
        return (sample.power == P_CHARGED_P && sample.phase_angle == P_CHARGED_PA);
    case TA:
        return (sample.power <= T_CHARGED_P && sample.phase_angle >= T_CHARGED_PA);
    case LT:
        return (sample.power < LT_CHARGED_P && sample.phase_angle > LT_CHARGED_PA);
    case "":
        return (sample.power == NONE_P && sample.phase_angle == NONE_PA);
    }
}

// on getting sample, check status
function getSample(sample) {
    server.log("Got 1 sample");
    server.log(format("type = %s", type));    
    server.log(format("power = %i", sample.power));    
    server.log(format("phase angle = %i", sample.phase_angle)); 
    server.log("");
    
    if (checkFull(sample, type)) {
        server.log("Battery full!");
        server.log("");
        device.send("full", 0);
        twilio.sendsms(PERS_NUM, "Done charging your " + type + "!");
        
    
    } 
}

// on receiving sms
http.onrequest(function(req, resp) {
    // path = agent url that receives texts (configured in twilio dashboard)
    local path = req.path.tolower();
    if (path == "/twilio" || path == "/twilio/") {
        // twilio request handler
        try {
            local data = http.urldecode(req.body);
            
            // parse response
            local device = data.Body.tolower();
            if (device == LT || 
            device == TA || 
            device == PH
        ) {
    ;        type <- device; 
                twilio.respondsms(resp, "Ok. Now charging your " + type + ".");
           }
           else twilio.respondsms(resp, "Sorry, that type of device isn't recognized.");
            
        } catch(ex) {
            local message = "Uh oh, something went horribly wrong: " + ex;
            twilio.respondsms(resp, message);
        }
    } else {
        // default request handler
        resp.send(200, "OK");
    }
});

// on start
twilio <- Twilio(TWILIO_SID, TWILIO_AUTH, TWILIO_NUM);
msg <- "Ready to start charging! Just plug in a device and press the button."
twilio.sendsms(PERS_NUM, msg);


// first sample
device.on("init", function(init) {
    getSample(init);
    checkDevice(init);
    server.log("Got initial sample: " + type);
    twilio.sendsms(PERS_NUM, "Now charging your " + type + ". If this is not the right device, text back the correct device.");
   
});

// continually collect samples until fully charged
device.on("sample", getSample);