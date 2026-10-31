package main

import "core:math"
import "core:time"

CAMERA_PLATE_WIDTH_FRACTION :: f32(0.25)
BUILD_PLATE_HALF_EXTENT :: f32(110)

camera_distance_max :: proc(camera: Camera, viewport: UI_Rect) -> f32 {
	aspect := f32(max(0.01, viewport.w/max(1, viewport.h)))
	projected_width := 2*BUILD_PLATE_HALF_EXTENT*(abs(math.sin(camera.yaw))+abs(math.cos(camera.yaw)))
	return max(f32(0.1), projected_width/(2*CAMERA_PLATE_WIDTH_FRACTION*math.tan(f32(0.78/2))*aspect))
}

camera_spring :: proc(value, velocity: ^f32, goal, dt, tolerance: f32) -> bool {
	omega: f32 = 32
	offset := value^ - goal
	impulse := velocity^ + omega*offset
	decay := math.exp(-omega*dt)
	value^ = goal + (offset + impulse*dt)*decay
	velocity^ = (velocity^ - omega*impulse*dt)*decay
	if abs(value^-goal) <= tolerance && abs(velocity^) <= tolerance*omega {
		value^ = goal
		velocity^ = 0
		return false
	}
	return true
}

app_animate_camera :: proc() {
	now := time.tick_now()
	dt := f32(0)
	if app.camera_tick != {} {dt = f32(time.duration_seconds(time.tick_since(app.camera_tick)))}
	app.camera_tick = now
	if !app.camera_initialized {return}
	previous := app.camera
	viewport := ui_viewport_rect(&app.ui)
	app.camera_goal.distance = min(app.camera_goal.distance, camera_distance_max(app.camera_goal, viewport))
	moving := false
	position_tolerance := max(f32(0.00001), app.camera_goal.distance*0.00001)
	moving = camera_spring(&app.camera.target.x, &app.camera_velocity.target.x, app.camera_goal.target.x, dt, position_tolerance) || moving
	moving = camera_spring(&app.camera.target.y, &app.camera_velocity.target.y, app.camera_goal.target.y, dt, position_tolerance) || moving
	moving = camera_spring(&app.camera.target.z, &app.camera_velocity.target.z, app.camera_goal.target.z, dt, position_tolerance) || moving
	moving = camera_spring(&app.camera.yaw, &app.camera_velocity.yaw, app.camera_goal.yaw, dt, 0.00001) || moving
	moving = camera_spring(&app.camera.pitch, &app.camera_velocity.pitch, app.camera_goal.pitch, dt, 0.00001) || moving
	moving = camera_spring(&app.camera.distance, &app.camera_velocity.distance, app.camera_goal.distance, dt, position_tolerance) || moving
	distance_max := camera_distance_max(app.camera, viewport)
	if app.camera.distance < 0.1 || app.camera.distance > distance_max {
		app.camera.distance = clamp_f32(app.camera.distance, 0.1, distance_max)
		app.camera_velocity.distance = 0
	}
	if abs(app.camera.pitch) > 1.45 {
		app.camera.pitch = clamp_f32(app.camera.pitch, -1.45, 1.45)
		app.camera_velocity.pitch = 0
	}
	if moving || previous != app.camera {app.needs_redraw = true}
}
