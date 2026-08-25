//
//  ChatMessageTemplateSelector.cs
//  MarkdownWin
//
//  Picks the transcript row template by ChatMessage.Kind.
//

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace MarkdownWin;

internal sealed class ChatMessageTemplateSelector : DataTemplateSelector
{
    public DataTemplate? UserTemplate { get; set; }
    public DataTemplate? AssistantTemplate { get; set; }
    public DataTemplate? ToolTemplate { get; set; }
    public DataTemplate? NoticeTemplate { get; set; }

    protected override DataTemplate? SelectTemplateCore(object item) => item switch
    {
        ChatMessage { Kind: ChatMessageKind.User } => UserTemplate,
        ChatMessage { Kind: ChatMessageKind.Assistant } => AssistantTemplate,
        ChatMessage { Kind: ChatMessageKind.Tool } => ToolTemplate,
        ChatMessage { Kind: ChatMessageKind.Notice } => NoticeTemplate,
        _ => null,
    };

    protected override DataTemplate? SelectTemplateCore(object item, DependencyObject container) =>
        SelectTemplateCore(item);
}
