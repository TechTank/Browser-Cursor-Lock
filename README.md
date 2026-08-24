# Browser Cursor Lock

<p align="center">
  <img src="https://github.com/user-attachments/assets/9b3f7694-ffde-4b89-8ad2-1c5a7d340d36" alt="logo">
</p>

A lightweight **AutoIt** utility that keeps the mouse cursor inside browser-based games, helping prevent accidental movement outside the game window or into browser interface elements.

Browser Cursor Lock can be controlled manually with a configurable hotkey or set to automatically lock the cursor when supported games or browsers enter fullscreen.

## 🚀 Features

- **🎮 Built for browser gaming** - keeps the cursor contained so accidental movement outside the game does not interrupt play.
- **🔒 Manual or automatic cursor locking** - use a hotkey when you want control, or let Browser Cursor Lock handle fullscreen sessions automatically.
- **🌐 Flexible browser and game detection** - includes common browsers and games while allowing custom definitions for others.
- **📐 Fine-tuned cursor boundaries** - adjust the lock area to account for browser UI, game layouts, and fullscreen differences.
- **⚙️ Fully configurable** - manage detection, hotkeys, notifications, and supported games from the built-in Settings window.
- **🖥️ Designed to stay out of the way** - runs from the system tray and only activates where configured.

## 🌐 Browser Support

Browser Cursor Lock includes default support for:

- Brave
- Google Chrome
- Mozilla Firefox
- Microsoft Edge
- Opera

Additional browsers can be added through the configuration window.

## 🎮 Game Support

Default game definitions are included for:

- Agar.io
- Diep.io
- Digdig.io
- Paper.io
- Snake.io
- Wormate.io

Additional browser games can be added through the configuration window.

## ⚙️ Configuration

Open **Settings** from the Browser Cursor Lock system tray icon.

The configuration window lets you manage:

- Cursor locking behavior
- Automatic fullscreen locking
- Lock and unlock hotkey
- Browser detection
- Game detection
- Cursor boundaries and offsets
- Notification behavior and appearance

## 📐 Cursor Offsets

Browser Cursor Lock supports separate cursor boundaries for browser and game windows.

Offsets can be configured independently for windowed and fullscreen modes using:

```text
Top, Right, Bottom, Left
```

This makes it possible to keep the cursor away from browser controls or other areas that should remain outside the usable game space.

## ⌨️ Hotkey

The default lock and unlock hotkey is:

```text
NUMPAD -
```

The hotkey can be changed from the Settings window using the built-in hotkey capture.

## 📄 Configuration File

Settings are stored in:

```text
browser cursor lock.ini
```

The configuration file is stored in the same directory as Browser Cursor Lock.

## 🔧 Requirements

- Windows 7, 8, 10, or 11
- AutoIt if running the `.au3` source directly

## 🧑‍💻 Author

Created by [Brogan Scott Houston McIntyre (TechTank)](https://github.com/TechTank)
