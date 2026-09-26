# Proper test driver for the 10moons graphics tablet

import os
import sys

# Specification of the device https://python-evdev.readthedocs.io/en/latest/
from evdev import UInput, ecodes, AbsInfo
# Establish usb communication with device
import usb
import yaml

path = os.path.join(os.path.dirname(__file__), "config.yaml")
# Loading tablet configuration
with open(path, "r") as f:
    config = yaml.load(f, Loader=yaml.FullLoader)


# Get the required ecodes from configuration
pen_codes = []
btn_codes = []
for k, v in config["actions"].items():
    codes = btn_codes if k == "tablet_buttons" else pen_codes
    if isinstance(v, list):
        codes.extend(v)
    else:
        codes.append(v)


temp = []
for c in pen_codes:
    temp.extend([ecodes.ecodes[x] for x in c.split("+")])
pen_codes = temp

temp = []
for c in btn_codes:
    temp.extend([ecodes.ecodes[x] for x in c.split("+")])
btn_codes = temp

pen_events = {
    ecodes.EV_KEY: pen_codes,
    ecodes.EV_ABS: [
        #AbsInfo input: value, min, max, fuzz, flat
        (ecodes.ABS_X, AbsInfo(0, 0, config["pen"]["max_x"], 0, 0, config["pen"]["resolution_x"])),
        (ecodes.ABS_Y, AbsInfo(0, 0, config["pen"]["max_y"], 0, 0, config["pen"]["resolution_y"])),
        (ecodes.ABS_PRESSURE, AbsInfo(0, 0, config["pen"]["max_pressure"], 0, 0, 0))
    ],
}

btn_events = {ecodes.EV_KEY: btn_codes}
# Find the device
dev = usb.core.find(idVendor=config["vendor_id"], idProduct=config["product_id"])
if dev == None:
    print('No Device Connected')
    exit(1)

try:
    # Select interface 2 and get the first endpoint under it (0x85)
    interface_index = 2
    ep = dev[0].interfaces()[interface_index].endpoints()[0]
    print(f"Success: Pen data path configured. Interface No: 2, Endpoint Address: {hex(ep.bEndpointAddress)}")
except Exception as e:
    print(f"Error while selecting interface: {e}")
    sys.exit(1)

# dev.reset() was removed - it was causing disconnections.


# Drop default kernel driver from all devices
for j in [0, 1, 2]:
    if dev.is_kernel_driver_active(j):
        dev.detach_kernel_driver(j)

# Set new configuration
dev.set_configuration()

vpen = UInput(events=pen_events, name=config["xinput_name"], version=0x3)
vbtn = UInput(events=btn_events, name=config["xinput_name"] + "_buttons", version=0x3)

pressed = -1

# Direction and axis configuration
max_x = config["pen"]["max_x"] * config["settings"]["swap_direction_x"]
max_y = config["pen"]["max_y"] * config["settings"]["swap_direction_y"]
x1, x2, y1, y2 = (3, 2, 5, 4) if config["settings"]["swap_axis"] else (5, 4, 3, 2)

# Screen Mapping
width_precent = config["screen_mapping"]["width_percent"] / 100
height_precent = config["screen_mapping"]["height_percent"] / 100
x_offset = config["screen_mapping"]["x_offset_percent"] * config["pen"]["max_x"] / 100
y_offset = config["screen_mapping"]["y_offset_percent"] * config["pen"]["max_y"] / 100

last_data = None

# Jitter filter settings (0 disables the filter)
smoothing = float(config.get("filter", {}).get("smoothing", 0.35))
deadzone = int(config.get("filter", {}).get("deadzone", 2))
smooth_x, smooth_y = None, None
report_x, report_y = None, None

# Infinite loop
while True:
    try:
        data = dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, timeout=5000)

        if data != last_data:
            print(f"Data changed! Raw Data (Bytes): {list(data)}")
            last_data = data

        # Use direct equality check instead of list to avoid getting stuck
        is_pen_action = False
        if data[1] == 192:
            is_pen_action = True
        if data[1] == 193:
            is_pen_action = True

        if is_pen_action: # Pen actions
            pen_x = int((abs(max_x - (data[x1] * 255 + data[x2])) * width_precent) + x_offset)
            pen_y = int((abs(max_y - (data[y1] * 255 + data[y2])) * height_precent) + y_offset)
            pen_pressure = data[7] * 255 + data[6]
            # Exponential moving average to reduce jitter
            if smoothing <= 0 or smooth_x is None:
                smooth_x, smooth_y = float(pen_x), float(pen_y)
            else:
                smooth_x += smoothing * (pen_x - smooth_x)
                smooth_y += smoothing * (pen_y - smooth_y)
            # Deadzone: ignore tiny movements around last reported position
            if report_x is None or abs(smooth_x - report_x) >= deadzone or abs(smooth_y - report_y) >= deadzone:
                report_x, report_y = int(round(smooth_x)), int(round(smooth_y))
            # Pen in proximity, required for the cursor to move
            vpen.write(ecodes.EV_KEY, ecodes.BTN_TOOL_PEN, 1)
            vpen.write(ecodes.EV_ABS, ecodes.ABS_X, report_x)
            vpen.write(ecodes.EV_ABS, ecodes.ABS_Y, report_y)
            vpen.write(ecodes.EV_ABS, ecodes.ABS_PRESSURE, pen_pressure)
            if data[1] == 192: # Pen hovering
                vpen.write(ecodes.EV_KEY, ecodes.BTN_TOUCH, 0)
            else: # Pen touching
                vpen.write(ecodes.EV_KEY, ecodes.BTN_TOUCH, 1)
        elif data[0] == 2: # Tablet button actions
            # press types: 0 - up; 1 - down; 2 - hold
            press_type = 1
            if data[1] == 2: # First button
                pressed = 0
            elif data[1] == 4: # Second button
                pressed = 1
            elif data[3] == 44: # Third button
                pressed = 2
            elif data[3] == 43: # Fourth button
                pressed = 3
            elif data[1] == 1 and data[3] == 28: # First button on the Pen
                pressed = 4
            elif data[1] == 1 and data[3] == 29: # Second button on the Pen
                pressed = 5
            else:
                press_type = 0
            key_codes = config["actions"]["tablet_buttons"][pressed].split("+")
            for key in key_codes:
                act = ecodes.ecodes[key]
                vbtn.write(ecodes.EV_KEY, act, press_type)
        # Flush
        vpen.syn()
        vbtn.syn()
    except usb.core.USBError as e:
        if len(e.args) > 0 and e.args[0] == 110:
            # Read timeout, pen is idle: reset filter so next stroke starts fresh
            smooth_x, smooth_y = None, None
            report_x, report_y = None, None
            continue
        print(f"USB Error Caught: {str(e)} (Error Code: {e.args})")
        if len(e.args) > 0 and e.args[0] == 19:
            vpen.close()
            vbtn.close()
            raise Exception("Device has been disconnected")
    except KeyboardInterrupt:
        vpen.close()
        vbtn.close()
        sys.exit("\nDriver terminated successfully.")
    except Exception as e:
        print(f"A general error occurred: {e}")
