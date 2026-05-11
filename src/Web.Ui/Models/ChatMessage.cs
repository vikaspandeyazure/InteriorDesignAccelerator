using InteriorDesign.Shared.Contracts;

namespace InteriorDesign.Web.Ui.Models;

/// <summary>
/// One entry in the chat thread. Either a "user" prompt string or an
/// "assistant" turn that wraps a full <see cref="DesignResponse"/>.
/// </summary>
public sealed class ChatMessage
{
    public required string Role { get; init; }   // "user" | "assistant"
    public string? Text { get; set; }
    public DesignResponse? Result { get; set; }
    public bool Pending { get; set; }
}
