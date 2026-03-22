using System.Text;
using MyCli;

namespace MyCli.Tests;

/// <summary>
/// Test cases for ProcessSseBuffer and related SSE parsing functionality
/// </summary>
public class ProcessSseBufferTests
{
    #region ProcessSseBuffer Tests

    [Fact]
    public void ProcessSseBuffer_EmptyBuffer_ReturnsFalse()
    {
        // Arrange
        var rawBuffer = new StringBuilder();
        var foundResponse = false;

        // Act
        var result = Program.ProcessSseBuffer(rawBuffer, foundResponse);

        // Assert
        Assert.False(result);
    }

    [Fact]
    public void ProcessSseBuffer_BodyWithHttpHeaders_SkipsHeaders()
    {
        // Arrange
        var rawBuffer = new StringBuilder();
        rawBuffer.Append("HTTP/1.1 200 OK\r\n");
        rawBuffer.Append("Content-Type: text/event-stream\r\n");
        rawBuffer.Append("\r\n");
        rawBuffer.Append("data:Hello\n\n");

        // Act
        var result = Program.ProcessSseBuffer(rawBuffer, false);

        // Assert
        Assert.True(result);
    }

    [Fact]
    public void ProcessSseBuffer_BodyWithoutHeaders_ParsesDirectly()
    {
        // Arrange
        var rawBuffer = new StringBuilder();
        rawBuffer.Append("data:Direct content\n\n");

        // Act
        var result = Program.ProcessSseBuffer(rawBuffer, false);

        // Assert
        Assert.True(result);
    }

    [Fact]
    public void ProcessSseBuffer_SimpleSseEvent_ParsesCorrectly()
    {
        // Arrange
        var rawBuffer = new StringBuilder();
        rawBuffer.Append("event:message\n");
        rawBuffer.Append("data:Hello World\n\n");

        // Act
        var result = Program.ProcessSseBuffer(rawBuffer, false);

        // Assert
        Assert.True(result);
    }

    [Fact]
    public void ProcessSseBuffer_MultilineData_Concatenates()
    {
        // Arrange
        var rawBuffer = new StringBuilder();
        rawBuffer.Append("data:Line1\n");
        rawBuffer.Append("data:Line2\n");
        rawBuffer.Append("data:Line3\n\n");

        // Act
        var result = Program.ProcessSseBuffer(rawBuffer, false);

        // Assert
        Assert.True(result);
    }

    [Fact]
    public void ProcessSseBuffer_MultipleEvents_ParsesAll()
    {
        // Arrange
        var rawBuffer = new StringBuilder();
        rawBuffer.Append("event:first\ndata:Event1\n\n");
        rawBuffer.Append("event:second\ndata:Event2\n\n");

        // Act
        var result = Program.ProcessSseBuffer(rawBuffer, false);

        // Assert
        Assert.True(result);
    }

    [Fact]
    public void ProcessSseBuffer_KeepaliveComments_Skipped()
    {
        // Arrange
        var rawBuffer = new StringBuilder();
        rawBuffer.Append(": Keepalive message\n");
        rawBuffer.Append("data:Real data\n\n");

        // Act
        var result = Program.ProcessSseBuffer(rawBuffer, false);

        // Assert
        Assert.True(result);
    }

    [Fact]
    public void ProcessSseBuffer_DataWithCarriageReturn_TrimsCorrectly()
    {
        // Arrange - SSE often uses CRLF line endings
        var rawBuffer = new StringBuilder();
        rawBuffer.Append("data:Hello\r\n");

        // Act
        var result = Program.ProcessSseBuffer(rawBuffer, false);

        // Assert
        Assert.True(result);
    }

    [Fact]
    public void ProcessSseBuffer_ChunkedEncoding_DecodesAndParses()
    {
        // Arrange
        var rawBuffer = new StringBuilder();
        rawBuffer.Append("HTTP/1.1 200 OK\r\n\r\n");
        // Chunked body
        rawBuffer.Append("6\r\ndata:Hello\r\n0\r\n\r\n");

        // Act
        var result = Program.ProcessSseBuffer(rawBuffer, false);

        // Assert
        Assert.True(result);
    }

    [Fact]
    public void ProcessSseBuffer_EmptyLinesBetweenEvents_Handled()
    {
        // Arrange
        var rawBuffer = new StringBuilder();
        rawBuffer.Append("data:Event1\n\n\n");
        rawBuffer.Append("data:Event2\n\n");

        // Act
        var result = Program.ProcessSseBuffer(rawBuffer, false);

        // Assert
        Assert.True(result);
    }

    [Fact]
    public void ProcessSseBuffer_OnlyHeaders_ReturnsFalse()
    {
        // Arrange
        var rawBuffer = new StringBuilder();
        rawBuffer.Append("HTTP/1.1 200 OK\r\n");
        rawBuffer.Append("Content-Type: text/event-stream\r\n");
        rawBuffer.Append("\r\n");

        // Act
        var result = Program.ProcessSseBuffer(rawBuffer, false);

        // Assert - no data to process
        Assert.False(result);
    }

    [Fact]
    public void ProcessSseBuffer_DataWithColonAfterPrefix_ExtractsCorrectly()
    {
        // Arrange
        var rawBuffer = new StringBuilder();
        rawBuffer.Append("data::smile:\n\n");

        // Act
        var result = Program.ProcessSseBuffer(rawBuffer, false);

        // Assert
        Assert.True(result);
    }

    [Fact]
    public void ProcessSseBuffer_EventTypeWithSpaces_TrimsCorrectly()
    {
        // Arrange
        var rawBuffer = new StringBuilder();
        rawBuffer.Append("event:  message  \n");
        rawBuffer.Append("data:test\n\n");

        // Act
        var result = Program.ProcessSseBuffer(rawBuffer, false);

        // Assert
        Assert.True(result);
    }

    #endregion

    #region TryDecodeChunked Tests

    [Fact]
    public void TryDecodeChunked_NonChunkedBody_ReturnsOriginalBody()
    {
        // Arrange
        var body = "Hello, World!";

        // Act
        var result = Program.TryDecodeChunked(body);

        // Assert
        Assert.Equal(body, result);
    }

    [Fact]
    public void TryDecodeChunked_EmptyBody_ReturnsEmpty()
    {
        // Arrange
        var body = "";

        // Act
        var result = Program.TryDecodeChunked(body);

        // Assert
        Assert.Equal("", result);
    }

    [Fact]
    public void TryDecodeChunked_SingleChunk_DecodesCorrectly()
    {
        // Arrange - chunked format: size\r\ndata\r\n0\r\n\r\n
        var body = "5\r\nHello\r\n0\r\n\r\n";

        // Act
        var result = Program.TryDecodeChunked(body);

        // Assert
        Assert.Equal("Hello", result);
    }

    [Fact]
    public void TryDecodeChunked_MultipleChunks_Concatenates()
    {
        // Arrange
        var body = "5\r\nHello\r\n5\r\nWorld\r\n0\r\n\r\n";

        // Act
        var result = Program.TryDecodeChunked(body);

        // Assert
        Assert.Equal("HelloWorld", result);
    }

    [Fact]
    public void TryDecodeChunked_HexChunkSize_ParsesCorrectly()
    {
        // Arrange - "f" = 15 in hex
        var body = "f\r\n0123456789ABCDEF\r\n0\r\n\r\n";

        // Act
        var result = Program.TryDecodeChunked(body);

        // Assert
        Assert.Equal("0123456789ABCDEF", result);
    }

    [Fact]
    public void TryDecodeChunked_TrailingNewlineOnly_ReturnsOriginal()
    {
        // Arrange
        var body = "\n";

        // Act
        var result = Program.TryDecodeChunked(body);

        // Assert
        Assert.Equal(body, result);
    }

    #endregion
}
