const Dmc = @This();

pub const MemoryReader = struct {
    ptr: *const anyopaque,
    read_fn: *const fn (ptr: *const anyopaque, addr: u16) u8,

    pub fn init(ptr: anytype) MemoryReader {
        const T = @TypeOf(ptr);
        const info = @typeInfo(T);
        if (info != .pointer) @compileError("MemoryReader.init expects a pointer");
        const Child = info.pointer.child;

        const VTable = struct {
            pub fn read(p: *const anyopaque, addr: u16) u8 {
                const self: *const Child = @ptrCast(@alignCast(p));
                return Child.read(self, addr);
            }
        };

        return .{ .ptr = ptr, .read_fn = VTable.read };
    }

    pub fn read(self: MemoryReader, addr: u16) u8 {
        return self.read_fn(self.ptr, addr);
    }
};

irq_enabled: bool = false,
loop_flag: bool = false,
irq_pending: bool = false,
enabled: bool = false,

timer_period: u16 = periodTable(0),
timer_counter: u16 = periodTable(0),

output_level: u7 = 0,
sample_address: u16 = 0xc000,
sample_length: u16 = 1,
current_address: u16 = 0xc000,
bytes_remaining: u16 = 0,

sample_buffer: u8 = 0,
sample_buffer_empty: bool = true,
shift_register: u8 = 0,
bits_remaining: u4 = 8,
silence: bool = true,

pub fn write(self: *Dmc, reg: u16, value: u8) void {
    switch (reg) {
        0 => {
            self.irq_enabled = (value & 0x80) != 0;
            self.loop_flag = (value & 0x40) != 0;
            self.timer_period = periodTable(value & 0x0f);
            if (!self.irq_enabled) self.irq_pending = false;
        },
        1 => self.output_level = @as(u7, @truncate(value & 0x7f)),
        2 => self.sample_address = 0xc000 | (@as(u16, value) << 6),
        3 => self.sample_length = (@as(u16, value) << 4) | 1,
        else => {},
    }
}

pub fn setEnabled(self: *Dmc, on: bool) void {
    self.enabled = on;
    self.irq_pending = false;
    if (!on) {
        self.bytes_remaining = 0;
    } else if (self.bytes_remaining == 0) {
        self.restartSample();
    }
}

pub fn tick(self: *Dmc, reader: ?MemoryReader) u32 {
    var stalls: u32 = 0;
    if (self.sample_buffer_empty and self.bytes_remaining > 0) {
        if (reader) |r| {
            self.sample_buffer = r.read(self.current_address);
            self.sample_buffer_empty = false;
            self.current_address +%= 1;
            if (self.current_address == 0) self.current_address = 0x8000;
            self.bytes_remaining -= 1;
            stalls = 4;
            if (self.bytes_remaining == 0) {
                if (self.loop_flag) self.restartSample() else if (self.irq_enabled) self.irq_pending = true;
            }
        }
    }

    if (self.timer_counter == 0) {
        self.timer_counter = self.timer_period;
        self.clockOutput();
    } else {
        self.timer_counter -= 1;
    }
    return stalls;
}

pub fn output(self: *const Dmc) u7 {
    return self.output_level;
}

fn clockOutput(self: *Dmc) void {
    if (!self.silence) {
        if ((self.shift_register & 1) != 0) {
            if (self.output_level <= 125) self.output_level += 2;
        } else if (self.output_level >= 2) {
            self.output_level -= 2;
        }
    }
    self.shift_register >>= 1;
    self.bits_remaining -= 1;
    if (self.bits_remaining == 0) {
        self.bits_remaining = 8;
        if (self.sample_buffer_empty) {
            self.silence = true;
        } else {
            self.silence = false;
            self.shift_register = self.sample_buffer;
            self.sample_buffer_empty = true;
        }
    }
}

fn restartSample(self: *Dmc) void {
    self.current_address = self.sample_address;
    self.bytes_remaining = self.sample_length;
}

fn periodTable(index: u8) u16 {
    const table = [_]u16{ 428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106, 84, 72, 54 };
    return table[index & 0x0f];
}
