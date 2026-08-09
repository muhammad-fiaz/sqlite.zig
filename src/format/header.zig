const std = @import("std");

pub const size = 100;
pub const magic = "SQLite format 3\x00";

pub const Header = struct {
    page_size: u16 = 4096,
    write_version: u8 = 1,
    read_version: u8 = 1,
    reserved_bytes: u8 = 0,
    payload_fraction: u8 = 64,
    largest_payload_fraction: u8 = 32,
    min_payload_fraction: u8 = 32,
    change_counter: u32 = 0,
    database_size_pages: u32 = 0,
    first_freelist_page: u32 = 0,
    freelist_pages: u32 = 0,
    schema_cookie: u32 = 0,
    schema_format: u32 = 4,
    text_encoding: u32 = 1,
    user_version: u32 = 0,
    application_id: u32 = 0,

    pub fn encode(self: Header, out: *[size]u8) void {
        @memset(out, 0);
        @memcpy(out[0..16], magic);
        std.mem.writeInt(u16, out[16..18], self.page_size, .big);
        out[18] = self.write_version;
        out[19] = self.read_version;
        out[20] = self.reserved_bytes;
        out[21] = self.payload_fraction;
        out[22] = self.largest_payload_fraction;
        out[23] = self.min_payload_fraction;
        std.mem.writeInt(u32, out[24..28], self.change_counter, .big);
        std.mem.writeInt(u32, out[28..32], self.database_size_pages, .big);
        std.mem.writeInt(u32, out[32..36], self.first_freelist_page, .big);
        std.mem.writeInt(u32, out[36..40], self.freelist_pages, .big);
        std.mem.writeInt(u32, out[40..44], self.schema_cookie, .big);
        std.mem.writeInt(u32, out[44..48], self.schema_format, .big);
        std.mem.writeInt(u32, out[56..60], self.text_encoding, .big);
        std.mem.writeInt(u32, out[60..64], self.user_version, .big);
        std.mem.writeInt(u32, out[68..72], self.application_id, .big);
    }

    pub fn decode(bytes: *const [size]u8) error{InvalidHeader}!Header {
        if (!std.mem.eql(u8, bytes[0..16], magic)) return error.InvalidHeader;
        return .{
            .page_size = std.mem.readInt(u16, bytes[16..18], .big),
            .write_version = bytes[18],
            .read_version = bytes[19],
            .reserved_bytes = bytes[20],
            .payload_fraction = bytes[21],
            .largest_payload_fraction = bytes[22],
            .min_payload_fraction = bytes[23],
            .change_counter = std.mem.readInt(u32, bytes[24..28], .big),
            .database_size_pages = std.mem.readInt(u32, bytes[28..32], .big),
            .first_freelist_page = std.mem.readInt(u32, bytes[32..36], .big),
            .freelist_pages = std.mem.readInt(u32, bytes[36..40], .big),
            .schema_cookie = std.mem.readInt(u32, bytes[40..44], .big),
            .schema_format = std.mem.readInt(u32, bytes[44..48], .big),
            .text_encoding = std.mem.readInt(u32, bytes[56..60], .big),
            .user_version = std.mem.readInt(u32, bytes[60..64], .big),
            .application_id = std.mem.readInt(u32, bytes[68..72], .big),
        };
    }
};

test "database header round trip" {
    var bytes: [size]u8 = undefined;
    const original = Header{ .page_size = 8192, .database_size_pages = 3, .text_encoding = 1 };
    original.encode(&bytes);
    const decoded = try Header.decode(&bytes);
    try std.testing.expectEqual(original.page_size, decoded.page_size);
    try std.testing.expectEqual(original.database_size_pages, decoded.database_size_pages);
}
