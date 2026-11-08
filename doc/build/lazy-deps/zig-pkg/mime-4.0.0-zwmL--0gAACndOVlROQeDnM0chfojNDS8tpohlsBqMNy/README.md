# Zig Module for MIME Types

## Synopsis

```zig
const std = @import("std");
const mime = @import("mime");

test "html smoke test" {
    const mime_type = mime.extension_map.get(".html").?;
    try std.testing.expectEqualStrings("text/html", @tagName(mime_type));
}

test "bogus extension" {
    try std.testing.expect(mime.extension_map.get(".sillybogo") == null);
}
```
