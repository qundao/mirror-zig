const std = @import("std");
const mime = @import("mime");

test "the mime package better have jpg support" {
    try std.testing.expect(mime.extension_map.has(".jpg"));
}

// syntax
