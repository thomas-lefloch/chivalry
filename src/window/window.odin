package window

import "base:runtime"
import "core:fmt"
import "core:os"

import win "core:sys/windows"

/* Useful ressources
 * https://github.com/karl-zylinski/odin-win32-software-rendering/blob/main/win32_software_rendering.odin   
 * https://learn.microsoft.com/en-us/windows/win32/learnwin32/creating-a-window
 */



window_resized := false
window_minimized := false

create_window :: proc(wnd_title: win.LPCWSTR) -> win.HWND {
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	assert(instance != nil, "Failed to fetch current instance")

	class_name := wnd_title

	wc := win.WNDCLASSW {
		lpfnWndProc   = window_proc,
		hInstance     = instance,
		lpszClassName = class_name,
		hCursor       = win.LoadCursorW(nil, transmute([^]u16)win.IDC_ARROW),
	}

	win.RegisterClassW(&wc)

	hwnd := win.CreateWindowW(
		class_name,
		wnd_title,
		win.WS_OVERLAPPEDWINDOW | win.WS_VISIBLE , // Window style

		// Size and position
		win.CW_USEDEFAULT,
		win.CW_USEDEFAULT,
		win.CW_USEDEFAULT,
		win.CW_USEDEFAULT,
		nil, // Parent window    
		nil, // Menu
		instance, // Instance handle
		nil, // Additional application data
	)

	assert(hwnd != nil, "Window creation Failed")

	return hwnd
}

resize_handled:: proc() {
	window_resized = false
}


@(private)
window_proc :: proc "stdcall" (
	hwnd: win.HWND,
	uMsg: win.UINT,
	wParam: win.WPARAM,
	lParam: win.LPARAM,
) -> win.LRESULT {

	context = runtime.default_context()

	switch uMsg {
	case win.WM_DESTROY:
		win.PostQuitMessage(0)
		return 0
	case win.WM_SIZE:
		window_minimized = wParam == win.SIZE_MINIMIZED
		window_resized = true
	}
	return win.DefWindowProcW(hwnd, uMsg, wParam, lParam)
}
