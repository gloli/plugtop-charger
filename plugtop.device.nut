// Power sensor
class PL7223 {
    
    static MTP_ADDR      = 0x0000
    static DSP_CODE_ADDR = 0x2000
    static DSP_BUFF_ADDR = 0x3000
    static CONFIG_ADDR   = 0x3800
    
    static CMD_READ   = 0x4000
    static CMD_WRITE  = 0x8000
    static CMD_STATUS = 0xC000
    
    
    spi = null;
    pl_rst_l = null;
    cs_l = null;
    
    /***************************** Public Methods *****************************/
    constructor(_spi, _pl_rst_l, _cs_l) {
        spi = _spi;
        pl_rst_l = _pl_rst_l;   
        cs_l = _cs_l;
        
        _init();
    }
    
    function Sample() {
        
        //Check status until we're good
        cs_l.write(0);
        spi.write("\xF0\x00");
        local ready = false;
        for (local i = 0; i < 10; i++) {
            local status = spi.writeread("\xFF")[0];
            if (status & 0x80){
                ready = true;
                break;
            } else {
                imp.sleep(0.01);                
            }
        }
        cs_l.write(1);
    
        if (!ready) {
            // server.log("Not ready to read data yet.");
            return false;
        }
        
        //Read the data
        local b  = _readBlob(DSP_BUFF_ADDR | 0x00, 144);
        local b2 = _readBlob(CONFIG_ADDR   | 0x09, 2);

        // Basic calculations
        local voltage = _blobWord(b, 2) / 64.0;
        local _current = _blobWord(b, 8) / 256.0;
        local power   = _blobWord(b, 123);
        
        local va      = voltage * _current;
        local power_factor = power / va; 
        if (va == 0) power_factor = 0.0;
        local phase_angle  = (math.acos(power_factor)/(2*PI))*360;
        
        // Frequency = [Sample_cnt0/(ZCC_STOP-ZCC_START)]*[(ZCC_CNT-1)/2]
        local Sample_cnt0   = _blobWord(b2,0);
        local ZCC_cnt       = _blobWord(b,90);
        local ZCC_stop      = _blobWord(b,96);
        local ZCC_start     = _blobWord(b,102);
        
        if (ZCC_stop == ZCC_start) {
            return false;
        }
            
        local frequency = ((1.0 * Sample_cnt0) / (ZCC_stop - ZCC_start)) * ((ZCC_cnt - 1.0) / 2);

        // Send to agent
        return { 
            ts = time(),
            voltage = voltage,
            _current = _current,
            power = power,
            power_factor = power_factor,
            phase_angle = phase_angle,
            frequency = frequency,
        };
    }
    
    /********************* Private Methods - Do Not Call **********************/
    function _init() {
        // Reset PL into MCU mode
        // Set both RESET_L and CS_L low
        pl_rst_l.write(0);
        cs_l.write(0);
        imp.sleep(0.01);
        
        // Set RESET_L high to latch MCU mode
        pl_rst_l.write(1);
        imp.sleep(0.01);
    
        // Set CS_L high
        cs_l.write(1);
    
        //Wait for chip to be ready
        imp.sleep(0.01);
    
        // Check if chip is ready by reading register 0x60
        local r = _readConfig(0x60);
        
        if (r != 0x04) server.log(format("Init value of register 0x60 = 0x%02x", r));
        return (r == 0x04);
    }
    
    function _readConfig(addr){
        addr = CMD_READ | CONFIG_ADDR | addr;
    
        cs_l.write(0);
        spi.write(format("%c%c", (addr >> 8) & 0xFF, addr & 0xFF));
        local val = spi.readstring(1)[0];
        cs_l.write(1);
        return val;
    }
    
    function _readBlob(addr, num) {
        addr = CMD_READ | addr;
    
        cs_l.write(0);
        spi.write(format("%c%c", (addr >> 8) & 0xFF, addr & 0xFF));
        local val = spi.readblob(num);
        cs_l.write(1);
        return val;
    }
    
    function _blobWord(b, offset) {
        return( (b[offset+1] << 8) | b[offset] );
    }
}

// timing const
const INIT = 30;
const WAIT = 120;
const ON = 1;

// Relay:
ry_on    <- hardware.pin9;
ry_off   <- hardware.pinA;
// Front Button:
button   <- hardware.pin1;
// Power Monitoring:
spi      <- hardware.spi257;
cs_l     <- hardware.pin8;
pl_rst_l <- hardware.pinB;

// Configure Relays
ry_on.configure(DIGITAL_OUT, 0);
ry_off.configure(DIGITAL_OUT, 0);

ry_state <- 0; // default off

// turn imp on/off
function setRelay(state) {
    ry_state = state;
    if (state) {
        ry_on.write(1);
        imp.wakeup(0.1, function() { ry_on.write(0); });
    } else {
        ry_off.write(1);
        imp.wakeup(0.1, function() { ry_off.write(0); });
    }
}

// Button on the front of plugtop
button.configure(DIGITAL_IN, function() {
    local state = button.read();

    // on button release, start sampling
    if (state == 1) {
        setRelay(1);
        local toggle = imp.wakeup(INIT, initSample);
    }
});

// Configure Power Monitoring:
spi.configure(CLOCK_IDLE_LOW, 100);        
pl_rst_l.configure(DIGITAL_OUT, 1);
cs_l.configure(DIGITAL_OUT, 1);
        
pl <- PL7223(spi, pl_rst_l, cs_l);


// sampling functions
function initSample() {
    local init = pl.Sample();
    
    if (init != false) {
        agent.send("init", init);
    }
    sample();

}

// resample 
function sample() {
    local usage = pl.Sample();
    if (usage != false) {
        agent.send("sample", usage);
    }
    
    if (ry_state == ON) 
        local toggle = imp.wakeup(WAIT, sample);
    // still samples once after full???
}

// on start
setRelay(ON);

// when done charging
agent.on("full", setRelay);