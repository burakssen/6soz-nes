const OnePoleLowPass = @This();

state: f32 = 0,

pub fn process(self: *OnePoleLowPass, input: f32) f32 {
    self.state += (input - self.state) * 0.20;
    return self.state;
}
