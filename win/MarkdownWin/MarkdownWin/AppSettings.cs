//
//  AppSettings.cs
//  MarkdownWin
//
//  Rendering options the settings window owns, stored in ApplicationData.Current.LocalSettings
//  and pushed to the web UI, which does the actual rendering. Mirrors WebPreferences.swift.
//
//  Requires the app to be running with a packaged (MSIX) identity — launched through the
//  packaging project's activation path, not a bare `dotnet run`/direct .exe double-click.
//

using System.Text.Json.Nodes;
using Windows.Foundation.Collections;
using Windows.Storage;

namespace MarkdownWin;

internal static class PreferenceKey
{
    public const string OutlineVisible = "outlineVisible";
    public const string ContentWidth = "contentWidth";
    public const string FontSize = "fontSize";
    public const string Appearance = "appearance";
    public const string AccountName = "accountName";
    public const string AccountEmail = "accountEmail";
}

/// <summary>Light, dark, or whatever the system is doing.</summary>
internal enum AppAppearance
{
    System,
    Light,
    Dark,
}

internal static class AppAppearanceExtensions
{
    public static string Label(this AppAppearance value) => value switch
    {
        AppAppearance.System => "Auto",
        AppAppearance.Light => "Light",
        AppAppearance.Dark => "Dark",
        _ => "Auto",
    };

    public static string ToRaw(this AppAppearance value) => value switch
    {
        AppAppearance.Light => "light",
        AppAppearance.Dark => "dark",
        _ => "system",
    };

    public static AppAppearance FromRaw(string? raw) => raw switch
    {
        "light" => AppAppearance.Light,
        "dark" => AppAppearance.Dark,
        _ => AppAppearance.System,
    };
}

/// <summary>How wide the rendered document is allowed to run.</summary>
internal enum ContentWidth
{
    /// Fills the pane, the behaviour before this option existed.
    Full,
    /// Caps the measure so long lines stay readable.
    Page,
}

internal static class ContentWidthExtensions
{
    public static string Label(this ContentWidth value) => value == ContentWidth.Page ? "Page width" : "Full width";

    public static string ToRaw(this ContentWidth value) => value == ContentWidth.Page ? "page" : "full";

    public static ContentWidth FromRaw(string? raw) => raw == "page" ? ContentWidth.Page : ContentWidth.Full;
}

internal static class FontSizeRange
{
    public const double Standard = 16.0;
    public const double Min = 11.0;
    public const double Max = 24.0;
}

/// <summary>The snapshot handed to the web UI.</summary>
internal readonly record struct WebPreferences(bool OutlineVisible, ContentWidth ContentWidth, double FontSize)
{
    /// <summary>Shape the web UI's `normalizePreferences` expects.</summary>
    public JsonObject ToPayload() => new()
    {
        ["outlineVisible"] = OutlineVisible,
        ["contentWidth"] = ContentWidth.ToRaw(),
        ["fontSize"] = FontSize,
    };
}

internal static class AppSettings
{
    private static IPropertySet Values => ApplicationData.Current.LocalSettings.Values;

    public static bool OutlineVisible
    {
        get => Values.TryGetValue(PreferenceKey.OutlineVisible, out object? value) && value is bool b ? b : true;
        set => Values[PreferenceKey.OutlineVisible] = value;
    }

    public static ContentWidth ContentWidth
    {
        get => ContentWidthExtensions.FromRaw(Values[PreferenceKey.ContentWidth] as string);
        set => Values[PreferenceKey.ContentWidth] = value.ToRaw();
    }

    public static double FontSize
    {
        get => Values.TryGetValue(PreferenceKey.FontSize, out object? value) && value is double d ? d : FontSizeRange.Standard;
        set => Values[PreferenceKey.FontSize] = value;
    }

    public static AppAppearance Appearance
    {
        get => AppAppearanceExtensions.FromRaw(Values[PreferenceKey.Appearance] as string);
        set => Values[PreferenceKey.Appearance] = value.ToRaw();
    }

    public static string? AccountName
    {
        get => Values[PreferenceKey.AccountName] as string;
        set => Values[PreferenceKey.AccountName] = value;
    }

    public static string? AccountEmail
    {
        get => Values[PreferenceKey.AccountEmail] as string;
        set => Values[PreferenceKey.AccountEmail] = value;
    }

    public static WebPreferences CurrentPreferences() => new(OutlineVisible, ContentWidth, FontSize);

    public static void ResetToDefaults()
    {
        Appearance = AppAppearance.System;
        ContentWidth = ContentWidth.Full;
        FontSize = FontSizeRange.Standard;
    }

    public static bool IsAtDefaults() =>
        Appearance == AppAppearance.System && ContentWidth == ContentWidth.Full && FontSize == FontSizeRange.Standard;
}
