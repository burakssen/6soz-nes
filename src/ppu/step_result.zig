const StepResult = @This();

cycles: u32,
audio: []const f32 = &.{},
frame_complete: bool = false,
