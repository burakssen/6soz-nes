const DcBlocker = @This();

prev_input: f32 = 0,
prev_output: f32 = 0,

pub fn process(self: *DcBlocker, input: f32) f32 {
    const output = input - self.prev_input + 0.995 * self.prev_output;
    self.prev_input = input;
    self.prev_output = output;
    return output;
}
