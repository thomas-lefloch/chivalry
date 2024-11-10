package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "window"

import win "core:sys/windows"
import vk "vendor:vulkan"
import vk_helper "vulkan_helper"

// Project TODO
// [x] Open a window
// [x] Display a Triangle in that window
// [ ] Display a Sprite 
// [ ] Animate the sprite 
// [ ] make it move and attack on key press


TARGET_FRAMERATE :: 60 // fps

main :: proc() {

	// display a window
	hwnd := window.create_window(win.L("Win32 + Vulkan Exploration"))

	vk_state := vk_helper.init(hwnd)
	defer vk_helper.deinit(&vk_state)

	run := true

	delta_time: time.Duration
	run_loop: for run { // we are doing too much work we don't need to go that fast
		start_time := time.now()

		msg: win.MSG
		for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
			switch msg.message {
			case win.WM_QUIT:
				run = false
				break run_loop
			}
			win.TranslateMessage(&msg)
			win.DispatchMessageW(&msg)
		}

		if window.window_minimized do continue // we just wait for the window to be reopened again

		if window.window_resized {
			start_resize := time.now()
			vk_helper.recreate_swapchain(&vk_state)
			end_resize := time.now()
			fmt.println("swapchain recreation took", time.diff(start_resize, end_resize))
			window.window_resized = false // I don't think it is a good idea to manage state this way
			// I do it this way because it is the easiest way
			// We cannot handle the win.WM_SIZE event in the PeekMessage loop. These events are directly 
			// sent to the window proc. Honestly I'm not sure  why we need a PeekMessage loop 
			// 
			// A better way, might be to store the window events thrown in the window proc into a FIFO 
			// queue and let the user application unpack all those messages 
		}

		vk_helper.draw_frame(&vk_state)

		delta_time = time.diff(start_time, time.now())
		// Quick and dirty fps but we also lock events handling	 and render to target fps
		// I'm not sure if this will cause problems. We will find out... or not
		// interesting reads:
		// https://medium.com/@tglaiel/how-to-make-your-game-run-at-60fps-24c61210fe75
		// https://gafferongames.com/post/fix_your_timestep/
		sleep_duration := (1/TARGET_FRAMERATE) - delta_time
		if sleep_duration > 0 do time.sleep((1/TARGET_FRAMERATE) - delta_time) 
	}

	vk.DeviceWaitIdle(vk_state.device)
}
