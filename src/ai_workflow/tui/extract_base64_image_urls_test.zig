const std = @import("std");
const tree1_mod = @import("nalarcore");
const helpers = tree1_mod.helpers;

const extractBase64ImageUrls = helpers.image.extractBase64ImageUrls;

// ============================================================================
// BASIC FUNCTIONALITY TESTS
// ============================================================================

test "extractBase64ImageUrls - single image" {
    const allocator = std.testing.allocator;
    const message = "Hello, here is an image: data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAUA";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAUA", result[0]);
}

test "extractBase64ImageUrls - multiple images" {
    const allocator = std.testing.allocator;
    const message = "First image: data:image/png;base64,AAAA Second image: data:image/jpeg;base64,BBBB Third: data:image/gif;base64,CCCC";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(3, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,AAAA", result[0]);
    try std.testing.expectEqualStrings("data:image/jpeg;base64,BBBB", result[1]);
    try std.testing.expectEqualStrings("data:image/gif;base64,CCCC", result[2]);
}

test "extractBase64ImageUrls - no images" {
    const allocator = std.testing.allocator;
    const message = "This is a plain text message without any images.";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(0, result.len);
}

test "extractBase64ImageUrls - empty message" {
    const allocator = std.testing.allocator;
    const message = "";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(0, result.len);
}

// ============================================================================
// IMAGE POSITION TESTS
// ============================================================================

test "extractBase64ImageUrls - image at start" {
    const allocator = std.testing.allocator;
    const message = "data:image/png;base64,abcdefghijk Hello world";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,abcdefghijk", result[0]);
}

test "extractBase64ImageUrls - image at end with no trailing space" {
    const allocator = std.testing.allocator;
    const message = "Here is the image data:image/png;base64,abcdefghijk";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,abcdefghijk", result[0]);
}

test "extractBase64ImageUrls - image in middle" {
    const allocator = std.testing.allocator;
    const message = "Before text data:image/png;base64,MMMM After text";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,MMMM", result[0]);
}

// ============================================================================
// DIFFERENT TERMINATOR TESTS (space, newline, tab, carriage return)
// ============================================================================

test "extractBase64ImageUrls - terminated by space" {
    const allocator = std.testing.allocator;
    const message = "data:image/png;base64,ABCD next text";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,ABCD", result[0]);
}

test "extractBase64ImageUrls - terminated by newline" {
    const allocator = std.testing.allocator;
    const message = "data:image/png;base64,ABCD\nnext line";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,ABCD", result[0]);
}

test "extractBase64ImageUrls - terminated by carriage return" {
    const allocator = std.testing.allocator;
    const message = "data:image/png;base64,ABCD\rnext line";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,ABCD", result[0]);
}

test "extractBase64ImageUrls - terminated by CRLF" {
    const allocator = std.testing.allocator;
    const message = "data:image/png;base64,ABCD\r\nnext line";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,ABCD", result[0]);
}

test "extractBase64ImageUrls - terminated by tab" {
    const allocator = std.testing.allocator;
    const message = "data:image/png;base64,ABCD\tnext text";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,ABCD", result[0]);
}

test "extractBase64ImageUrls - image with newlines in text" {
    const allocator = std.testing.allocator;
    const message = "Line 1\ndata:image/png;base64,AAAA\nLine 2";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,AAAA", result[0]);
}

// ============================================================================
// DIFFERENT IMAGE MIME TYPES
// ============================================================================

test "extractBase64ImageUrls - png format" {
    const allocator = std.testing.allocator;
    const message = "data:image/png;base64,AAAA";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,AAAA", result[0]);
}

test "extractBase64ImageUrls - jpeg format" {
    const allocator = std.testing.allocator;
    const message = "data:image/jpeg;base64,BBBB";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/jpeg;base64,BBBB", result[0]);
}

test "extractBase64ImageUrls - gif format" {
    const allocator = std.testing.allocator;
    const message = "data:image/gif;base64,CCCC";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/gif;base64,CCCC", result[0]);
}

test "extractBase64ImageUrls - webp format" {
    const allocator = std.testing.allocator;
    const message = "data:image/webp;base64,DDDD";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/webp;base64,DDDD", result[0]);
}

test "extractBase64ImageUrls - avif format" {
    const allocator = std.testing.allocator;
    const message = "data:image/avif;base64,EEEE";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/avif;base64,EEEE", result[0]);
}

test "extractBase64ImageUrls - svg+xml format" {
    const allocator = std.testing.allocator;
    const message = "data:image/svg+xml;base64,FFFF";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/svg+xml;base64,FFFF", result[0]);
}

test "extractBase64ImageUrls - bmp format" {
    const allocator = std.testing.allocator;
    const message = "data:image/bmp;base64,GGGG";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/bmp;base64,GGGG", result[0]);
}

test "extractBase64ImageUrls - tiff format" {
    const allocator = std.testing.allocator;
    const message = "data:image/tiff;base64,HHHH";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/tiff;base64,HHHH", result[0]);
}

// ============================================================================
// BASE64 PADDING TESTS
// ============================================================================

test "extractBase64ImageUrls - single padding (=)" {
    const allocator = std.testing.allocator;
    const message = "data:image/png;base64,ABCD=";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,ABCD=", result[0]);
}

test "extractBase64ImageUrls - double padding (==)" {
    const allocator = std.testing.allocator;
    const message = "data:image/png;base64,ABC==";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,ABC==", result[0]);
}

test "extractBase64ImageUrls - real world PNG with padding" {
    const allocator = std.testing.allocator;
    // This is a real PNG header base64 encoded (1x1 transparent pixel)
    const message = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==", result[0]);
}

test "extractBase64ImageUrls - real world JPEG" {
    const allocator = std.testing.allocator;
    // JPEG header pattern
    const message = "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMCwsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAAKAAoDASIAAhEBAxEB/8QAFgABAQEAAAAAAAAAAAAAAAAAAAUH/8QAIhAAAQQBBAMBAAAAAAAAAAAAAQIDBBEABRIhMQYTQVH/xAAVAQEBAAAAAAAAAAAAAAAAAAAFB//EABsRAAICAwEAAAAAAAAAAAAAAAECAAMEESEx/9oADAMBAAIRAxEAPwCqt3bp2PIkR1R5CglK1AlIUASBkA4J/tQqve9bSFyXG48yUlS1FCVyGggFRJAABwBz51Oa1p6m0bItyIiEyJDq3FOOLUoqWo+SSR/dGlcU7jJPUr6N0eK/Z//2Q==";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMCwsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAAKAAoDASIAAhEBAxEB/8QAFgABAQEAAAAAAAAAAAAAAAAAAAUH/8QAIhAAAQQBBAMBAAAAAAAAAAAAAQIDBBEABRIhMQYTQVH/xAAVAQEBAAAAAAAAAAAAAAAAAAAFB//EABsRAAICAwEAAAAAAAAAAAAAAAECAAMEESEx/9oADAMBAAIRAxEAPwCqt3bp2PIkR1R5CglK1AlIUASBkA4J/tQqve9bSFyXG48yUlS1FCVyGggFRJAABwBz51Oa1p6m0bItyIiEyJDq3FOOLUoqWo+SSR/dGlcU7jJPUr6N0eK/Z//2Q==", result[0]);
}

// ============================================================================
// CONSECUTIVE AND MULTIPLE IMAGE TESTS
// ============================================================================

test "extractBase64ImageUrls - consecutive images without spaces" {
    const allocator = std.testing.allocator;
    const message = "data:image/png;base64,AAAAdata:image/jpeg;base64,BBBB";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(2, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,AAAA", result[0]);
    try std.testing.expectEqualStrings("data:image/jpeg;base64,BBBB", result[1]);
}

test "extractBase64ImageUrls - five images with various formats" {
    const allocator = std.testing.allocator;
    const message = "img1: data:image/png;base64,AAA img2: data:image/jpeg;base64,BBB img3: data:image/gif;base64,CCC img4: data:image/webp;base64,DDD img5: data:image/png;base64,EEE";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(5, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,AAA", result[0]);
    try std.testing.expectEqualStrings("data:image/jpeg;base64,BBB", result[1]);
    try std.testing.expectEqualStrings("data:image/gif;base64,CCC", result[2]);
    try std.testing.expectEqualStrings("data:image/webp;base64,DDD", result[3]);
    try std.testing.expectEqualStrings("data:image/png;base64,EEE", result[4]);
}

test "extractBase64ImageUrls - ten images for stress test" {
    const allocator = std.testing.allocator;
    const message = "data:image/png;base64,A1 data:image/png;base64,A2 data:image/png;base64,A3 data:image/png;base64,A4 data:image/png;base64,A5 data:image/png;base64,A6 data:image/png;base64,A7 data:image/png;base64,A8 data:image/png;base64,A9 data:image/png;base64,A10";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(10, result.len);
}

// ============================================================================
// EDGE CASES - DO NOT MATCH
// ============================================================================

test "extractBase64ImageUrls - partial marker doesn't match" {
    const allocator = std.testing.allocator;
    const message = "data:image but no base64 marker here";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(0, result.len);
}

test "extractBase64ImageUrls - base64 marker without prefix" {
    const allocator = std.testing.allocator;
    const message = "text;base64,something but no data:image prefix";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(0, result.len);
}

test "extractBase64ImageUrls - url/http images not matched" {
    const allocator = std.testing.allocator;
    const message = "Check this image: https://example.com/image.png or http://example.com/image.jpg";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(0, result.len);
}

test "extractBase64ImageUrls - data without image type not matched" {
    const allocator = std.testing.allocator;
    const message = "data:text/plain;base64,SGVsbG8gV29ybGQ=";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(0, result.len);
}

test "extractBase64ImageUrls - dataimage prefix without base64" {
    const allocator = std.testing.allocator;
    const message = "data:image/png;base32,ABCD";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(0, result.len);
}

test "extractBase64ImageUrls - text that looks like partial match" {
    const allocator = std.testing.allocator;
    const message = "The data:image prefix appears in normal text but ;base64, is missing";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(0, result.len);
}

test "extractBase64ImageUrls - malformed image URL" {
    const allocator = std.testing.allocator;
    const message = "data:image/png;base64";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    // No data after base64 marker
    try std.testing.expectEqual(0, result.len);
}

// ============================================================================
// REAL WORLD USAGE SCENARIOS
// ============================================================================

test "extractBase64ImageUrls - user message with image" {
    const allocator = std.testing.allocator;
    const message = "Can you explain what this code does?\n\ndata:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==\n\nThanks!";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
}

test "extractBase64ImageUrls - JSON-like structure" {
    const allocator = std.testing.allocator;
    const message = "{\"image\": \"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAUA\"}";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAUA", result[0]);
}

test "extractBase64ImageUrls - markdown with image" {
    const allocator = std.testing.allocator;
    const message = "Here's a screenshot:\n\n![screenshot](data:image/png;base64,AAAA)\n\nLet me know if you need more info.";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
}

test "extractBase64ImageUrls - multiple images in user message" {
    const allocator = std.testing.allocator;
    const message = "I'm looking at two screenshots. First one shows the login page and second shows the error message:\n\ndata:image/png;base64,AAAA\n\ndata:image/png;base64,BBBB";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(2, result.len);
}

test "extractBase64ImageUrls - image URL followed by punctuation" {
    const allocator = std.testing.allocator;
    const message = "Look at this:image.png data:image/png;base64,ABCD.";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,ABCD", result[0]);
}

test "extractBase64ImageUrls - multiple images with punctuation" {
    const allocator = std.testing.allocator;
    const message = "Image1: data:image/png;base64,AAA. Image2: data:image/jpeg;base64,BBB, Image3: data:image/gif;base64,CCC!";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(3, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,AAA", result[0]);
    try std.testing.expectEqualStrings("data:image/jpeg;base64,BBB", result[1]);
    try std.testing.expectEqualStrings("data:image/gif;base64,CCC", result[2]);
}

// ============================================================================
// MEMORY LEAK VERIFICATION TESTS
// ============================================================================

test "extractBase64ImageUrls - memory verify each URL is distinct allocation" {
    const allocator = std.testing.allocator;
    const message = "data:image/png;base64,AAAA data:image/png;base64,BBBB data:image/png;base64,CCCC";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    // Verify all URLs are distinct (not pointing to same memory)
    // Compare by checking they have different starting positions in original message
    const ptr0 = @intFromPtr(result[0].ptr);
    const ptr1 = @intFromPtr(result[1].ptr);
    const ptr2 = @intFromPtr(result[2].ptr);
    try std.testing.expect(ptr0 != ptr1);
    try std.testing.expect(ptr1 != ptr2);
    try std.testing.expect(ptr0 != ptr2);
    
    // Verify they contain expected content
    try std.testing.expectEqualStrings("data:image/png;base64,AAAA", result[0]);
    try std.testing.expectEqualStrings("data:image/png;base64,BBBB", result[1]);
    try std.testing.expectEqualStrings("data:image/png;base64,CCCC", result[2]);
}

test "extractBase64ImageUrls - large base64 data" {
    const allocator = std.testing.allocator;
    // Create a message with a large base64 string (1000 chars of 'A')
    const large_base64 = "A" ** 1000;
    const message = std.fmt.allocPrint(allocator, "data:image/png;base64,{s}", .{large_base64}) catch unreachable;
    defer allocator.free(message);
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqual(1021, result[0].len); // "data:image/png;base64," (21) + 1000
}

test "extractBase64ImageUrls - empty result still returns valid slice" {
    const allocator = std.testing.allocator;
    const message = "No images here";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    // Empty result should be a valid empty slice, not null
    try std.testing.expectEqual(0, result.len);
    try std.testing.expect(result.len == 0);
}

test "extractBase64ImageUrls - single character base64 data" {
    const allocator = std.testing.allocator;
    const message = "data:image/png;base64,A";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,A", result[0]);
}

test "extractBase64ImageUrls - very long base64 without padding" {
    const allocator = std.testing.allocator;
    // 100 'B' characters
    const long_base64 = "B" ** 100;
    const message = try std.fmt.allocPrint(allocator, "data:image/png;base64,{s}", .{long_base64});
    defer allocator.free(message);
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    // Length should be "data:image/png;base64," (21) + 100
    try std.testing.expectEqual(122, result[0].len);
}

// ============================================================================
// BOUNDARY AND SPECIAL CHARACTER TESTS
// ============================================================================

test "extractBase64ImageUrls - image URL at absolute start with no preceding chars" {
    const allocator = std.testing.allocator;
    const message = "data:image/png;base64,START";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,START", result[0]);
}

test "extractBase64ImageUrls - base64 with special chars / + =" {
    const allocator = std.testing.allocator;
    // Real base64 can contain / and + characters
    const message = "data:image/png;base64,ABC/DEF+GHI=";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,ABC/DEF+GHI=", result[0]);
}

test "extractBase64ImageUrls - unicode in message around image" {
    const allocator = std.testing.allocator;
    const message = "日本語data:image/png;base64,UNICODE日本語";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(1, result.len);
    // No whitespace after UNICODE, but non-ASCII bytes are not base64 chars so stop at i=7
    try std.testing.expectEqualStrings("data:image/png;base64,UNICODE", result[0]);
}

test "extractBase64ImageUrls - mixed content with multiple images" {
    const allocator = std.testing.allocator;
    const message = "Start data:image/png;base64,IMG1 middle data:image/jpeg;base64,IMG2 end data:image/gif;base64,IMG3 done";
    
    const result = try extractBase64ImageUrls(message, allocator);
    defer {
        for (result) |url| allocator.free(url);
        allocator.free(result);
    }
    
    try std.testing.expectEqual(3, result.len);
    try std.testing.expectEqualStrings("data:image/png;base64,IMG1", result[0]);
    try std.testing.expectEqualStrings("data:image/jpeg;base64,IMG2", result[1]);
    try std.testing.expectEqualStrings("data:image/gif;base64,IMG3", result[2]);
}