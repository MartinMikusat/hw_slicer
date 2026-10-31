package main

import "core:math"
import "core:time"

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
	moving := false
	position_tolerance := max(f32(0.00001), app.camera_goal.distance*0.00001)
	moving = camera_spring(&app.camera.target.x, &app.camera_velocity.target.x, app.camera_goal.target.x, dt, position_tolerance) || moving
	moving = camera_spring(&app.camera.target.y, &app.camera_velocity.target.y, app.camera_goal.target.y, dt, position_tolerance) || moving
	moving = camera_spring(&app.camera.target.z, &app.camera_velocity.target.z, app.camera_goal.target.z, dt, position_tolerance) || moving
	moving = camera_spring(&app.camera.yaw, &app.camera_velocity.yaw, app.camera_goal.yaw, dt, 0.00001) || moving
	moving = camera_spring(&app.camera.pitch, &app.camera_velocity.pitch, app.camera_goal.pitch, dt, 0.00001) || moving
	moving = camera_spring(&app.camera.distance, &app.camera_velocity.distance, app.camera_goal.distance, dt, position_tolerance) || moving
	if app.camera.distance < 0.1 || app.camera.distance > 100000 {
		app.camera.distance = clamp_f32(app.camera.distance, 0.1, 100000)
		app.camera_velocity.distance = 0
	}
	if abs(app.camera.pitch) > 1.45 {
		app.camera.pitch = clamp_f32(app.camera.pitch, -1.45, 1.45)
		app.camera_velocity.pitch = 0
	}
	if moving || previous != app.camera {app.needs_redraw = true}
}
