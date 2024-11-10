package vulkan_helper

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"

import vk "vendor:vulkan"

/*
 * Vulkan implementation sources: 
 * https://vulkan-tutorial.com/
 * https://harrylovescode.gitbooks.io/vulkan-api/content/chap02/chap02.html
 * https://gist.github.com/terickson001/bdaa52ce621a6c7f4120abba8959ffe6
 * https://github.com/lucypero/vulkan-odin/blob/master/main.odin
 */

Queue :: struct {
	vk_handle: vk.Queue,
	index:     u32,
}

Shader :: struct {
	filename: string,
	stage:    vk.ShaderStageFlags,
}

Context :: struct {
	instance:        vk.Instance,
	surface:         vk.SurfaceKHR,
	physical_device: vk.PhysicalDevice,
	device:          vk.Device,
	graphic_queue:   Queue,
	present_queue:   Queue,
	surface_format:  vk.SurfaceFormatKHR,
	swapchain:       vk.SwapchainKHR,
	image_views:     []vk.ImageView,
	extent:          vk.Extent2D, // TODO: really necessary ????
	shaders_modules: [len(SHADERS)]vk.ShaderModule,
	render_pass:     vk.RenderPass,
	pipeline_layout: vk.PipelineLayout,
	pipeline:        vk.Pipeline,
	framebuffers:    []vk.Framebuffer,
	command_pool:    vk.CommandPool,
	command_buffers: [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
	image_available: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
	render_finished: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
	in_flight:       [MAX_FRAMES_IN_FLIGHT]vk.Fence,
	current_frame:   int,
	hwnd:            win.HWND,
}

MAX_FRAMES_IN_FLIGHT :: 2

SHADERS := [?]Shader {
	{filename = "build/shaders/vert.spv", stage = {.VERTEX}},
	{filename = "build/shaders/frag.spv", stage = {.FRAGMENT}},
}

INSTANCE_EXTENSIONS := [?]cstring {
	vk.KHR_SURFACE_EXTENSION_NAME,
	vk.KHR_WIN32_SURFACE_EXTENSION_NAME,
}

VALIDATION_LAYERS := [?]cstring{"VK_LAYER_KHRONOS_validation"}

DEVICE_EXTENSIONS := [?]cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}

DEVICE_FEATURES := vk.PhysicalDeviceFeatures{}

DYNAMIC_STATES := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}


init :: proc(hwnd: win.HWND) -> Context {
	assert(hwnd != nil, "Window handle is nil")
	ctx: Context = {
		hwnd = hwnd,
	}


	lib, lib_ok := dynlib.load_library("vulkan-1.dll")
	assert(lib_ok, "vulkan-1.dll not found")

	ptr, ptr_ok := dynlib.symbol_address(lib, "vkGetInstanceProcAddr")
	assert(ptr_ok, "vkGetInstanceProcAddr symbols addresses not found")

	vk.load_proc_addresses_global(ptr)

	// List availables extensions
	// {
	// 	vk_extension_property_count: u32
	// 	vk.EnumerateInstanceExtensionProperties(nil, &vk_extension_property_count, nil)
	// 	vk_extension_properties := make([]vk.ExtensionProperties, vk_extension_property_count)
	// 	defer delete(vk_extension_properties)
	// 	vk.EnumerateInstanceExtensionProperties(
	// 		nil,
	// 		&vk_extension_property_count,
	// 		&vk_extension_properties[0],
	// 	)

	// 	fmt.println("Available extensions:")

	// 	for i: u32 = 0; i < vk_extension_property_count; i += 1 {
	// 		fmt.println("\t", cstring(&(vk_extension_properties[i].extensionName[0])))
	// 	}
	// }


	// TODO: check availability of extensions
	// TODO: check availability of validation layers

	createInfo: vk.InstanceCreateInfo = {
		sType                   = .INSTANCE_CREATE_INFO,
		enabledExtensionCount   = u32(len(INSTANCE_EXTENSIONS)),
		ppEnabledExtensionNames = &INSTANCE_EXTENSIONS[0],
		enabledLayerCount       = len(VALIDATION_LAYERS),
		ppEnabledLayerNames     = &VALIDATION_LAYERS[0],
	}
	result := vk.CreateInstance(&createInfo, nil, &ctx.instance)
	assert(result == .SUCCESS, "Failed to instanciate vulkan")

	vk.load_proc_addresses_instance(ctx.instance)

	{ 	// Surface
		surfaceInfo: vk.Win32SurfaceCreateInfoKHR = {
			sType     = .WIN32_SURFACE_CREATE_INFO_KHR,
			hwnd      = hwnd,
			hinstance = win.HINSTANCE(win.GetModuleHandleW(nil)),
		}
		result = vk.CreateWin32SurfaceKHR(ctx.instance, &surfaceInfo, nil, &ctx.surface)
		assert(result == .SUCCESS, "Failed to create win32 KHR surface")
	}

	ctx.physical_device = choose_physical_device(ctx.instance, ctx.surface)
	assert(ctx.physical_device != nil, "physical_device is null")

	{
		queue_family_count: u32 = 0
		vk.GetPhysicalDeviceQueueFamilyProperties(ctx.physical_device, &queue_family_count, nil)
		available_queue_families := make([]vk.QueueFamilyProperties, queue_family_count)
		defer delete(available_queue_families)

		vk.GetPhysicalDeviceQueueFamilyProperties(
			ctx.physical_device,
			&queue_family_count,
			&available_queue_families[0],
		)

		for family, i in available_queue_families {
			if .GRAPHICS in family.queueFlags {
				ctx.graphic_queue.index = u32(i)
			}

			present_supported: b32 = false
			vk.GetPhysicalDeviceSurfaceSupportKHR(
				ctx.physical_device,
				u32(i),
				ctx.surface,
				&present_supported,
			)
			if present_supported do ctx.present_queue.index = u32(i)
		}
		assert(ctx.graphic_queue.index >= 0, "Graphic queue not found")
		assert(ctx.present_queue.index >= 0, "Present queue not found")

		queue_priority: f32 = 1.0

		queue_create_infos := [?]vk.DeviceQueueCreateInfo {
			vk.DeviceQueueCreateInfo {
				sType = .DEVICE_QUEUE_CREATE_INFO,
				queueFamilyIndex = ctx.graphic_queue.index,
				queueCount = 1,
				pQueuePriorities = &queue_priority,
			},
			vk.DeviceQueueCreateInfo {
				sType = .DEVICE_QUEUE_CREATE_INFO,
				queueFamilyIndex = ctx.present_queue.index,
				queueCount = 1,
				pQueuePriorities = &queue_priority,
			},
		}

		device_create_info := vk.DeviceCreateInfo {
			sType                   = .DEVICE_CREATE_INFO,
			pEnabledFeatures        = &DEVICE_FEATURES,
			queueCreateInfoCount    = u32(len(queue_create_infos)),
			pQueueCreateInfos       = &queue_create_infos[0],

			// no device specific extension for now
			enabledExtensionCount   = len(DEVICE_EXTENSIONS),
			ppEnabledExtensionNames = &DEVICE_EXTENSIONS[0],

			// Aparently the following fields are ignored by up-to-date implemantation
			// setting them for backward compatibility 
			// TODO: find the last hardware that uses this
			// https://vulkan-tutorial.com/Drawing_a_triangle/Setup/Logical_device_and_queues#:~:text=Previous%20implementations%20of,with%20older%20implementations%3A
			// https://registry.khronos.org/vulkan/specs/1.3-extensions/man/html/VkDeviceCreateInfo.html#:~:text=enabledLayerCount%20is%20deprecated%20and%20ignored,ppEnabledLayerNames%20is%20deprecated%20and%20ignored
			enabledLayerCount       = len(VALIDATION_LAYERS),
			ppEnabledLayerNames     = &VALIDATION_LAYERS[0],
		}

		result = vk.CreateDevice(ctx.physical_device, &device_create_info, nil, &ctx.device)
		assert(result == .SUCCESS, "Failed to create logical device")

		vk.GetDeviceQueue(ctx.device, ctx.graphic_queue.index, 0, &ctx.graphic_queue.vk_handle)
		// Maybe the same handle as the graphic queue
		vk.GetDeviceQueue(ctx.device, ctx.present_queue.index, 0, &ctx.present_queue.vk_handle)
	}

	create_swapchain_and_image_views(&ctx)

	{ 	
		shader_stages := [len(SHADERS)]vk.PipelineShaderStageCreateInfo{}

		for shader, i in SHADERS {
			code := read_shader(shader.filename)
			// Saving them because we need to destroy them. but when ?
			ctx.shaders_modules[i] = create_shader_module(ctx.device, code)

			shader_stage_create_info := vk.PipelineShaderStageCreateInfo {
				sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage  = shader.stage,
				module = ctx.shaders_modules[i],
				pName  = "main",
			}
			shader_stages[i] = shader_stage_create_info
		}

		color_attachment := vk.AttachmentDescription {
			format         = ctx.surface_format.format,
			samples        = {._1},
			loadOp         = .CLEAR,
			storeOp        = .STORE,
			stencilLoadOp  = .DONT_CARE,
			stencilStoreOp = .DONT_CARE,
			initialLayout  = .UNDEFINED,
			finalLayout    = .PRESENT_SRC_KHR,
		}
		color_attachment_ref := vk.AttachmentReference {
			attachment = 0,
			layout     = .COLOR_ATTACHMENT_OPTIMAL,
		}
		subpass_info := vk.SubpassDescription {
			pipelineBindPoint    = .GRAPHICS,
			colorAttachmentCount = 1,
			pColorAttachments    = &color_attachment_ref,
		}

		subpass_dep := vk.SubpassDependency {
			srcSubpass    = vk.SUBPASS_EXTERNAL,
			srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
			srcAccessMask = {},
			dstSubpass    = 0,
			dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
			dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
		}
		render_pass_info := vk.RenderPassCreateInfo {
			sType           = .RENDER_PASS_CREATE_INFO,
			attachmentCount = 1,
			pAttachments    = &color_attachment,
			subpassCount    = 1,
			pSubpasses      = &subpass_info,
			dependencyCount = 1,
			pDependencies   = &subpass_dep,
		}
		result = vk.CreateRenderPass(ctx.device, &render_pass_info, nil, &ctx.render_pass)
		assert(result == .SUCCESS, "Failed to create render pass")

		dynamic_infos := vk.PipelineDynamicStateCreateInfo {
			sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
			dynamicStateCount = len(DYNAMIC_STATES),
			pDynamicStates    = &DYNAMIC_STATES[0],
		}

		vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
			sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
			vertexBindingDescriptionCount   = 0,
			pVertexBindingDescriptions      = nil,
			vertexAttributeDescriptionCount = 0,
			pVertexAttributeDescriptions    = nil,
		}

		input_assembly_info := vk.PipelineInputAssemblyStateCreateInfo {
			sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
			topology               = .TRIANGLE_LIST,
			primitiveRestartEnable = false,
		}

		viewport := vk.Viewport {
			x        = 0,
			y        = 0,
			width    = f32(ctx.extent.width),
			height   = f32(ctx.extent.height),
			minDepth = 0,
			maxDepth = 1,
		}

		viewport_info := vk.PipelineViewportStateCreateInfo {
			sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
			scissorCount  = 1,
			viewportCount = 1,
		}

		rasterizer_info := vk.PipelineRasterizationStateCreateInfo {
			sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
			depthClampEnable        = false,
			rasterizerDiscardEnable = false,
			polygonMode             = .FILL,
			lineWidth               = 1,
			cullMode                = {.BACK},
			frontFace               = .CLOCKWISE,
			depthBiasEnable         = false,
		}

		multisampling_info := vk.PipelineMultisampleStateCreateInfo {
			sType                 = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
			sampleShadingEnable   = false,
			rasterizationSamples  = {._1},
			minSampleShading      = 1,
			pSampleMask           = nil,
			alphaToCoverageEnable = false,
			alphaToOneEnable      = false,
		}

		corlorblend_attachement := vk.PipelineColorBlendAttachmentState {
			colorWriteMask      = {.R, .G, .B, .A},
			blendEnable         = false,
			srcColorBlendFactor = .ONE,
			dstColorBlendFactor = .ZERO,
			colorBlendOp        = .ADD,
			srcAlphaBlendFactor = .ONE,
			alphaBlendOp        = .ADD,
		}

		colorblend_create_info := vk.PipelineColorBlendStateCreateInfo {
			sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
			logicOpEnable   = false,
			attachmentCount = 1,
			pAttachments    = &corlorblend_attachement,
			blendConstants  = {0, 0, 0, 0},
		}

		// no uniform at the moment
		pipeline_layout_info := vk.PipelineLayoutCreateInfo {
			sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
			setLayoutCount         = 0,
			pushConstantRangeCount = 0,
		}

		result = vk.CreatePipelineLayout(
			ctx.device,
			&pipeline_layout_info,
			nil,
			&ctx.pipeline_layout,
		)
		assert(result == .SUCCESS, "Failed to create pipeline layout")

		pipeline_info := vk.GraphicsPipelineCreateInfo {
			sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
			stageCount          = 2,
			pStages             = &shader_stages[0],
			pVertexInputState   = &vertex_input_info,
			pInputAssemblyState = &input_assembly_info,
			pViewportState      = &viewport_info,
			pRasterizationState = &rasterizer_info,
			pMultisampleState   = &multisampling_info,
			pColorBlendState    = &colorblend_create_info,
			pDepthStencilState  = nil,
			pDynamicState       = &dynamic_infos,
			layout              = ctx.pipeline_layout,
			renderPass          = ctx.render_pass,
			subpass             = 0,
		}

		result = vk.CreateGraphicsPipelines(ctx.device, 0, 1, &pipeline_info, nil, &ctx.pipeline)
		assert(result == .SUCCESS, "Failed to create graphic pipeline")
	}

	create_framebuffers(&ctx)

	{
		command_pool_create_info := vk.CommandPoolCreateInfo {
			sType            = .COMMAND_POOL_CREATE_INFO,
			flags            = {.RESET_COMMAND_BUFFER},
			queueFamilyIndex = ctx.graphic_queue.index,
		}
		result = vk.CreateCommandPool(
			ctx.device,
			&command_pool_create_info,
			nil,
			&ctx.command_pool,
		)
		assert(result == .SUCCESS, "Failed to create command pool")

		command_buffer_allocate_info := vk.CommandBufferAllocateInfo {
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool        = ctx.command_pool,
			level              = .PRIMARY,
			commandBufferCount = len(ctx.command_buffers),
		}
		result = vk.AllocateCommandBuffers(
			ctx.device,
			&command_buffer_allocate_info,
			&ctx.command_buffers[0],
		)
		assert(result == .SUCCESS, "Failed to allocate command buffers")
	}


	semaphore_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		result = vk.CreateSemaphore(ctx.device, &semaphore_info, nil, &ctx.image_available[i])
		assert(result == .SUCCESS, "Failed to create image_available semaphore")

		result = vk.CreateSemaphore(ctx.device, &semaphore_info, nil, &ctx.render_finished[i])
		assert(result == .SUCCESS, "Failed to create render_finished semaphore")

		result = vk.CreateFence(ctx.device, &fence_info, nil, &ctx.in_flight[i])
		assert(result == .SUCCESS, "Failed to create in_flight fence ")
	}
	return ctx
}

deinit :: proc(ctx: ^Context) {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.DestroyFence(ctx.device, ctx.in_flight[i], nil)
		vk.DestroySemaphore(ctx.device, ctx.image_available[i], nil)
		vk.DestroySemaphore(ctx.device, ctx.render_finished[i], nil)
	}

	vk.DestroyCommandPool(ctx.device, ctx.command_pool, nil)

	destroy_swapchain(ctx)

	vk.DestroyPipeline(ctx.device, ctx.pipeline, nil)
	vk.DestroyPipelineLayout(ctx.device, ctx.pipeline_layout, nil)
	vk.DestroyRenderPass(ctx.device, ctx.render_pass, nil)
	for shader_mod in ctx.shaders_modules do vk.DestroyShaderModule(ctx.device,  shader_mod, nil)

	vk.DestroyDevice(ctx.device, nil)
	vk.DestroySurfaceKHR(ctx.instance, ctx.surface, nil)
	vk.DestroyInstance(ctx.instance, nil)
}

choose_physical_device :: proc(
	instance: vk.Instance,
	surface: vk.SurfaceKHR,
) -> vk.PhysicalDevice {
	assert(instance != nil, "Instance is nil")

	device_count: u32 = 0
	vk.EnumeratePhysicalDevices(instance, &device_count, nil)
	assert(device_count > 0, "No device found, vulkan not supported")
	devices := make([]vk.PhysicalDevice, device_count)
	defer delete(devices)
	vk.EnumeratePhysicalDevices(instance, &device_count, &devices[0])

	device_loop: for device in devices {
		properties: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(device, &properties)
		fmt.println(cstring(&properties.deviceName[0]))

		extension_count: u32 = 0
		vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, nil)

		available_extensions := make([]vk.ExtensionProperties, extension_count)
		defer delete(available_extensions)
		vk.EnumerateDeviceExtensionProperties(
			device,
			nil,
			&extension_count,
			&available_extensions[0],
		)

		device_support_extension := true
		// TODO: better algorithm (availables are stringified for each req_ext
		for required_ext in DEVICE_EXTENSIONS {
			required_ext_name := string(required_ext)
			supported := false
			available_loop: for i := 0; i < len(available_extensions); i += 1 {
				available_ext_name := strings.trim_null(
					strings.string_from_ptr(
						&available_extensions[i].extensionName[0],
						vk.MAX_EXTENSION_NAME_SIZE,
					),
				)
				if strings.compare(required_ext_name, available_ext_name) == 0 {
					supported = true
					fmt.printfln("%s supported", required_ext_name)
					break available_loop
				}
			}
			if supported == false {
				fmt.printfln("Required extension %s not supported", required_ext)
				continue device_loop
			}
		}

		swapchain_details := query_swapchain_details(device, surface)
		defer free_swapchain_details(&swapchain_details)

		if len(swapchain_details.formats) == 0 || len(swapchain_details.present_modes) == 0 {
			continue device_loop
		}
	}

	// It would be a good idea to rate and select the best device
	return devices[0]
}

SwapchainSupportDetails :: struct {
	capabilities:  vk.SurfaceCapabilitiesKHR,
	formats:       []vk.SurfaceFormatKHR,
	present_modes: []vk.PresentModeKHR,
}

query_swapchain_details :: proc(
	physical_device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
) -> SwapchainSupportDetails {

	details: SwapchainSupportDetails

	result := vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
		physical_device,
		surface,
		&details.capabilities,
	)

	format_count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, nil)

	details.formats = make([]vk.SurfaceFormatKHR, format_count)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(
		physical_device,
		surface,
		&format_count,
		&details.formats[0],
	)

	present_count: u32
	vk.GetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &present_count, nil)
	details.present_modes = make([]vk.PresentModeKHR, present_count)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(
		physical_device,
		surface,
		&present_count,
		&details.present_modes[0],
	)

	return details
}

free_swapchain_details :: proc(details: ^SwapchainSupportDetails) {
	delete(details.formats)
	delete(details.present_modes)
}

create_swapchain_and_image_views :: proc(ctx: ^Context) {
	swapchain_details := query_swapchain_details(ctx.physical_device, ctx.surface)
	defer free_swapchain_details(&swapchain_details)

	ideal_format_found := false
	for format in swapchain_details.formats {
		if format.format == .B8G8R8A8_SRGB && format.colorSpace == .COLORSPACE_SRGB_NONLINEAR {
			ctx.surface_format = format
			ideal_format_found = true
			break
		}
	}
	if ideal_format_found == false { 	//we settle for the first one
		ctx.surface_format = swapchain_details.formats[0]
	}

	present_mode: vk.PresentModeKHR
	for mode in swapchain_details.present_modes {
		if mode == .MAILBOX {
			present_mode = mode
		}
	}
	if present_mode == nil {
		present_mode = .FIFO //guaranted
	}

	if swapchain_details.capabilities.currentExtent.width != max(u32) {
		ctx.extent = swapchain_details.capabilities.currentExtent
	} else {
		rect: win.RECT
		// TODO: keep track of window size with resize callback
		if (win.GetWindowRect(ctx.hwnd, &rect)) {
			ctx.extent = {
				width  = clamp(
					u32(rect.right - rect.left),
					swapchain_details.capabilities.minImageExtent.width,
					swapchain_details.capabilities.minImageExtent.width,
				),
				height = clamp(
					u32(rect.bottom - rect.top),
					swapchain_details.capabilities.minImageExtent.height,
					swapchain_details.capabilities.maxImageExtent.height,
				),
			}
		} else {
			fmt.println(win.GetLastError())
			assert(false, "failed to retrieve window rect")
		}
	}

	image_count := swapchain_details.capabilities.minImageCount + 1
	if swapchain_details.capabilities.maxImageCount > 0 {
		image_count = min(image_count, swapchain_details.capabilities.maxImageCount)
	}

	swapchain_create_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = ctx.surface,
		minImageCount    = image_count,
		imageFormat      = ctx.surface_format.format,
		imageColorSpace  = ctx.surface_format.colorSpace,
		imageExtent      = ctx.extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		preTransform     = swapchain_details.capabilities.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = present_mode,
		clipped          = true,
	}

	queue_indices := [2]u32{ctx.graphic_queue.index, ctx.present_queue.index}
	if queue_indices[0] != queue_indices[1] {
		swapchain_create_info.imageSharingMode = .CONCURRENT
		swapchain_create_info.queueFamilyIndexCount = 2
		swapchain_create_info.pQueueFamilyIndices = &queue_indices[0]
	} else {
		swapchain_create_info.imageSharingMode = .EXCLUSIVE
	}


	result := vk.CreateSwapchainKHR(ctx.device, &swapchain_create_info, nil, &ctx.swapchain)
	assert(result == .SUCCESS, "Failed to create swapchain")

	swapchain_image_count: u32
	vk.GetSwapchainImagesKHR(ctx.device, ctx.swapchain, &swapchain_image_count, nil)
	swapchain_images := make([]vk.Image, swapchain_image_count)
	//defer delete(swapchain_images)
	// cleaned up by vulkan when we destroy swapchain
	vk.GetSwapchainImagesKHR(
		ctx.device,
		ctx.swapchain,
		&swapchain_image_count,
		&swapchain_images[0],
	)


	ctx.image_views = make([]vk.ImageView, len(swapchain_images))
	for i := 0; i < len(ctx.image_views); i += 1 {
		info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = swapchain_images[i],
			viewType = .D2,
			format = ctx.surface_format.format,
			components = {r = .IDENTITY, g = .IDENTITY, b = .IDENTITY, a = .IDENTITY},
			subresourceRange = {
				aspectMask = {.COLOR},
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
		}
		result := vk.CreateImageView(ctx.device, &info, nil, &ctx.image_views[i])
		fmt.assertf(result == .SUCCESS, "Failed to create image view %d", i)
	}
}

create_framebuffers :: proc(ctx: ^Context) {
	ctx.framebuffers = make([]vk.Framebuffer, len(ctx.image_views))
	for image_view, i in ctx.image_views {
		attachment := [?]vk.ImageView{ctx.image_views[i]}

		framebuffer_info := vk.FramebufferCreateInfo {
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = ctx.render_pass,
			attachmentCount = 1,
			pAttachments    = &attachment[0],
			width           = ctx.extent.width,
			height          = ctx.extent.height,
			layers          = 1,
		}

		result := vk.CreateFramebuffer(ctx.device, &framebuffer_info, nil, &ctx.framebuffers[i])
		fmt.assertf(result == .SUCCESS, "Failed to create %d framebuffer", i)
	}
}

destroy_swapchain :: proc(ctx: ^Context) {
	for framebuffer in ctx.framebuffers do vk.DestroyFramebuffer(ctx.device, framebuffer, nil)
	for image_view in ctx.image_views do vk.DestroyImageView(ctx.device, image_view, nil)
	vk.DestroySwapchainKHR(ctx.device, ctx.swapchain, nil)
}

recreate_swapchain :: proc(ctx: ^Context) {
	vk.DeviceWaitIdle(ctx.device)
	destroy_swapchain(ctx)

	create_swapchain_and_image_views(ctx)
	create_framebuffers(ctx)
}

read_shader :: proc(filename: string) -> []byte {
	code, err := os.read_entire_file_from_filename_or_err(filename)
	fmt.assertf(err == nil, "Failed to read %s: %v", filename, err)
	return code
}

/*
* modules must be destroyed via vk.DestroyShaderModule()
*/
create_shader_module :: proc(
	device: vk.Device,
	code: []byte,
	flags: vk.ShaderModuleCreateFlags = {},
) -> vk.ShaderModule {
	info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = cast(^u32)&code[0],
		flags    = flags,
	}

	module: vk.ShaderModule
	result := vk.CreateShaderModule(device, &info, nil, &module)
	assert(result == .SUCCESS, "Failed to create shader module")
	return module
}

record_command_buffer :: proc(
	command_buffer: vk.CommandBuffer,
	render_pass: vk.RenderPass,
	framebuffer: vk.Framebuffer,
	swapchain_extent: vk.Extent2D,
	pipeline: vk.Pipeline,
) {
	begin_info := vk.CommandBufferBeginInfo {
		sType            = .COMMAND_BUFFER_BEGIN_INFO,
		flags            = {},
		pInheritanceInfo = nil,
	}
	result := vk.BeginCommandBuffer(command_buffer, &begin_info)
	assert(result == .SUCCESS, "Failed command_buffer begin info")

	clear_color: vk.ClearValue
	clear_color.color.float32 = [4]f32{0.0, 0.0, 0.0, 1.0}

	render_pass_begin_info := vk.RenderPassBeginInfo {
		sType = .RENDER_PASS_BEGIN_INFO,
		renderPass = render_pass,
		framebuffer = framebuffer,
		renderArea = {offset = {0, 0}, extent = swapchain_extent},
		clearValueCount = 1,
		pClearValues = &clear_color,
	}

	vk.CmdBeginRenderPass(command_buffer, &render_pass_begin_info, .INLINE)

	vk.CmdBindPipeline(command_buffer, .GRAPHICS, pipeline)

	viewport := vk.Viewport {
		x        = 0,
		y        = 0,
		width    = f32(swapchain_extent.width),
		height   = f32(swapchain_extent.height),
		minDepth = 0,
		maxDepth = 0,
	}
	vk.CmdSetViewport(command_buffer, 0, 1, &viewport)

	scissor := vk.Rect2D {
		offset = {0, 0},
		extent = swapchain_extent,
	}
	vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

	vk.CmdDraw(command_buffer, 3, 1, 0, 0)

	vk.CmdEndRenderPass(command_buffer)
	result = vk.EndCommandBuffer(command_buffer)
	assert(result == .SUCCESS, "Failed to end command buffer")
}

draw_frame :: proc(ctx: ^Context) {
	vk.WaitForFences(ctx.device, 1, &ctx.in_flight[ctx.current_frame], true, max(u64))

	image_index: u32
	result := vk.AcquireNextImageKHR(
		ctx.device,
		ctx.swapchain,
		max(u64),
		ctx.image_available[ctx.current_frame],
		0,
		&image_index,
	)
	if result == .ERROR_OUT_OF_DATE_KHR {
		// recreate_swapchain(ctx)
		return
	}

	vk.ResetFences(ctx.device, 1, &ctx.in_flight[ctx.current_frame])

	vk.ResetCommandBuffer(ctx.command_buffers[ctx.current_frame], {})
	record_command_buffer(
		ctx.command_buffers[ctx.current_frame],
		ctx.render_pass,
		ctx.framebuffers[image_index],
		ctx.extent,
		ctx.pipeline,
	)
	// wait_semaphores := [?]vk.Semaphore{image_available}
	wait_stages := [?]vk.PipelineStageFlags{{.COLOR_ATTACHMENT_OUTPUT}}
	submit_info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &ctx.image_available[ctx.current_frame],
		pWaitDstStageMask    = &wait_stages[0],
		commandBufferCount   = 1,
		pCommandBuffers      = &ctx.command_buffers[ctx.current_frame],
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &ctx.render_finished[ctx.current_frame],
	}

	result = vk.QueueSubmit(
		ctx.graphic_queue.vk_handle,
		1,
		&submit_info,
		ctx.in_flight[ctx.current_frame],
	)
	assert(result == .SUCCESS, "Failed to submit command to graphic queue")

	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &ctx.render_finished[ctx.current_frame],
		swapchainCount     = 1,
		pSwapchains        = &ctx.swapchain,
		pImageIndices      = &image_index,
		pResults           = nil,
	}
	result = vk.QueuePresentKHR(ctx.present_queue.vk_handle, &present_info)
	if result != .SUCCESS do fmt.println("Failed to present the image", result) // no assert here, it will fail when we close the window


	ctx.current_frame = (ctx.current_frame + 1) % MAX_FRAMES_IN_FLIGHT
}
