#!/bin/bash
set -euo pipefail

OBS_ROOT="${OBS_ROOT:-$HOME/Library/Application Support/obs-studio}"
COLLECTION_NAME="${COLLECTION_NAME:-SideScreen Galaxy Camera}"
PROFILE_NAME="${PROFILE_NAME:-SideScreen Galaxy Camera}"
PREVIEW_URL="${PREVIEW_URL:-http://127.0.0.1:54324/}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-30}"

SCENES_DIR="$OBS_ROOT/basic/scenes"
PROFILE_DIR="$OBS_ROOT/basic/profiles/$PROFILE_NAME"
COLLECTION_FILE="$SCENES_DIR/$COLLECTION_NAME.json"
GLOBAL_INI="$OBS_ROOT/global.ini"
USER_INI="$OBS_ROOT/user.ini"

mkdir -p "$SCENES_DIR" "$PROFILE_DIR"

python3 - "$COLLECTION_FILE" "$PROFILE_DIR/basic.ini" "$PROFILE_DIR/service.json" "$PROFILE_DIR/streamEncoder.json" "$GLOBAL_INI" "$USER_INI" "$COLLECTION_NAME" "$PROFILE_NAME" "$PREVIEW_URL" "$WIDTH" "$HEIGHT" "$FPS" <<'PY'
import configparser
import json
import os
import shutil
import sys
import uuid

(
    collection_file,
    profile_ini,
    service_json,
    stream_encoder_json,
    global_ini,
    user_ini,
    collection_name,
    profile_name,
    preview_url,
    width,
    height,
    fps,
) = sys.argv[1:]

width = int(width)
height = int(height)
fps = int(fps)
scene_name = "Galaxy Camera"
source_name = "SideScreen Galaxy Camera"
scene_uuid = str(uuid.uuid4())
source_uuid = str(uuid.uuid4())

source_defaults = {
    "prev_ver": 536936450,
    "uuid": source_uuid,
    "id": "browser_source",
    "versioned_id": "browser_source",
    "settings": {
        "url": preview_url,
        "width": width,
        "height": height,
        "fps": fps,
        "reroute_audio": False,
        "restart_when_active": True,
        "shutdown": False,
        "css": "html, body { margin: 0; overflow: hidden; background: #000; }",
    },
    "mixers": 0,
    "sync": 0,
    "flags": 0,
    "volume": 1.0,
    "balance": 0.5,
    "enabled": True,
    "muted": False,
    "push-to-mute": False,
    "push-to-mute-delay": 0,
    "push-to-talk": False,
    "push-to-talk-delay": 0,
    "hotkeys": {
        "libobs.mute": [],
        "libobs.unmute": [],
        "libobs.push-to-mute": [],
        "libobs.push-to-talk": [],
        "ObsBrowser.Refresh": [],
    },
    "deinterlace_mode": 0,
    "deinterlace_field_order": 0,
    "monitoring_type": 0,
    "private_settings": {},
}
source = {"name": source_name, **source_defaults}

scene = {
    "prev_ver": 536936450,
    "name": scene_name,
    "uuid": scene_uuid,
    "id": "scene",
    "versioned_id": "scene",
    "settings": {
        "id_counter": 1,
        "custom_size": False,
        "items": [
            {
                "name": source_name,
                "source_uuid": source_uuid,
                "visible": True,
                "locked": False,
                "rot": 0.0,
                "scale_ref": {"x": float(width), "y": float(height)},
                "align": 5,
                "bounds_type": 0,
                "bounds_align": 0,
                "bounds_crop": False,
                "crop_left": 0,
                "crop_top": 0,
                "crop_right": 0,
                "crop_bottom": 0,
                "id": 1,
                "group_item_backup": False,
                "pos": {"x": 0.0, "y": 0.0},
                "pos_rel": {"x": 0.0, "y": 0.0},
                "scale": {"x": 1.0, "y": 1.0},
                "scale_rel": {"x": 1.0, "y": 1.0},
                "bounds": {"x": 0.0, "y": 0.0},
                "bounds_rel": {"x": 0.0, "y": 0.0},
                "scale_filter": "disable",
                "blend_method": "default",
                "blend_type": "normal",
                "show_transition": {"duration": 0},
                "hide_transition": {"duration": 0},
                "private_settings": {},
            }
        ],
    },
    "mixers": 0,
    "sync": 0,
    "flags": 0,
    "volume": 1.0,
    "balance": 0.5,
    "enabled": True,
    "muted": False,
    "push-to-mute": False,
    "push-to-mute-delay": 0,
    "push-to-talk": False,
    "push-to-talk-delay": 0,
    "hotkeys": {},
    "deinterlace_mode": 0,
    "deinterlace_field_order": 0,
    "monitoring_type": 0,
    "private_settings": {},
}

collection = {
    "name": collection_name,
    "sources": [source, scene],
    "groups": [],
    "scene_order": [{"name": scene_name}],
    "current_scene": scene_name,
    "current_program_scene": scene_name,
    "canvases": [],
    "current_transition": "Fade",
    "transition_duration": 300,
    "transitions": [],
    "quick_transitions": [
        {
            "name": "Fade",
            "duration": 300,
            "hotkeys": [],
            "id": 1,
            "fade_to_black": False,
        }
    ],
    "saved_projectors": [],
    "preview_locked": False,
    "scaling_enabled": False,
    "scaling_level": 0,
    "scaling_off_x": 0.0,
    "scaling_off_y": 0.0,
    "virtual-camera": {"type2": 3},
    "modules": {
        "scripts-tool": [],
        "output-timer": {
            "streamTimerHours": 0,
            "streamTimerMinutes": 0,
            "streamTimerSeconds": 30,
            "recordTimerHours": 0,
            "recordTimerMinutes": 0,
            "recordTimerSeconds": 30,
            "autoStartStreamTimer": False,
            "autoStartRecordTimer": False,
            "pauseRecordTimer": True,
        },
        "auto-scene-switcher": {
            "interval": 300,
            "non_matching_scene": "",
            "switch_if_not_matching": False,
            "active": False,
            "switches": [],
        },
    },
    "resolution": {"x": width, "y": height},
    "migration_resolution": {"x": width, "y": height},
    "version": 2,
}

if os.path.exists(collection_file):
    backup = f"{collection_file}.bak"
    if not os.path.exists(backup):
        os.replace(collection_file, backup)

with open(collection_file, "w", encoding="utf-8") as handle:
    json.dump(collection, handle, ensure_ascii=False, indent=4)
    handle.write("\n")

config = configparser.ConfigParser()
config.optionxform = str
config["General"] = {"Name": profile_name}
config["Output"] = {"Mode": "Simple"}
config["SimpleOutput"] = {
    "RecEncoder": "x264",
    "RecQuality": "Stream",
    "FilePath": os.path.expanduser("~/Movies"),
    "StreamEncoder": "x264",
}
config["Video"] = {
    "BaseCX": str(width),
    "BaseCY": str(height),
    "OutputCX": str(width),
    "OutputCY": str(height),
    "FPSType": "0",
    "FPSCommon": str(fps),
    "FPSInt": str(fps),
    "FPSNum": str(fps),
    "FPSDen": "1",
    "ScaleType": "bicubic",
    "ColorFormat": "NV12",
    "ColorSpace": "709",
    "ColorRange": "Partial",
}
config["Audio"] = {
    "SampleRate": "48000",
    "ChannelSetup": "Stereo",
}

with open(profile_ini, "w", encoding="utf-8") as handle:
    config.write(handle, space_around_delimiters=False)

for path in (service_json, stream_encoder_json):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump({}, handle)
        handle.write("\n")

for ini_path in (global_ini, user_ini):
    if not os.path.exists(ini_path):
        continue
    obs_config = configparser.ConfigParser()
    obs_config.optionxform = str
    obs_config.read(ini_path, encoding="utf-8")
    if not obs_config.has_section("Basic"):
        obs_config.add_section("Basic")
    if obs_config.has_section("General"):
        obs_config["General"]["ConfirmOnExit"] = "false"
    backup = f"{ini_path}.sidescreen.bak"
    if not os.path.exists(backup):
        shutil.copy2(ini_path, backup)
    obs_config["Basic"]["Profile"] = profile_name
    obs_config["Basic"]["ProfileDir"] = profile_name
    obs_config["Basic"]["SceneCollection"] = collection_name
    obs_config["Basic"]["SceneCollectionFile"] = collection_name
    with open(ini_path, "w", encoding="utf-8") as handle:
        obs_config.write(handle, space_around_delimiters=False)
PY

echo "OBS profile ready: $PROFILE_NAME"
echo "OBS scene collection ready: $COLLECTION_NAME"
echo "Browser source URL: $PREVIEW_URL"
echo "OBS default profile/scene collection set to SideScreen"
