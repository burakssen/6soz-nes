const Sweep = @This();

enabled: bool = false,
period: u3 = 0,
negate: bool = false,
shift: u3 = 0,
divider: u3 = 0,
reload: bool = false,

pub fn write(self: *Sweep, value: u8) void {
    self.enabled = (value & 0x80) != 0;
    self.period = @truncate((value >> 4) & 0x07);
    self.negate = (value & 0x08) != 0;
    self.shift = @truncate(value & 0x07);
    self.reload = true;
}
