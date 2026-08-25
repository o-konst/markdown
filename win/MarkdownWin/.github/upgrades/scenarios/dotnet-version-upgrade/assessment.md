# Projects and dependencies analysis

This document provides a comprehensive overview of the projects and their dependencies in the context of upgrading to .NETCoreApp,Version=v10.0.

## Table of Contents

- [Executive Summary](#executive-Summary)
  - [Highlevel Metrics](#highlevel-metrics)
  - [Projects Compatibility](#projects-compatibility)
  - [Package Compatibility](#package-compatibility)
  - [API Compatibility](#api-compatibility)
  - [Binding Redirect Configuration](#binding-redirect-configuration)
- [Aggregate NuGet packages details](#aggregate-nuget-packages-details)
- [Top API Migration Challenges](#top-api-migration-challenges)
  - [Technologies and Features](#technologies-and-features)
  - [Most Frequent API Issues](#most-frequent-api-issues)
- [Projects Relationship Graph](#projects-relationship-graph)
- [Project Details](#project-details)

  - [MarkdownWin\MarkdownWin.csproj](#markdownwinmarkdownwincsproj)


## Executive Summary

### Highlevel Metrics

| Metric | Count | Status |
| :--- | :---: | :--- |
| Total Projects | 1 | All require upgrade |
| Total NuGet Packages | 2 | All compatible |
| Total Code Files | 7 |  |
| Total Code Files with Incidents | 6 |  |
| Total Lines of Code | 894 |  |
| Total Number of Issues | 20 |  |
| Estimated LOC to modify | 19+ | at least 2.1% of codebase |

### Projects Compatibility

| Project | Target Framework | Difficulty | Package Issues | API Issues | Binding Issues | Est. LOC Impact | Description |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :--- |
| [MarkdownWin\MarkdownWin.csproj](#markdownwinmarkdownwincsproj) | net8.0-windows10.0.19041.0 | 🟢 Low | 0 | 19 | 0 | 19+ | WinForms, Sdk Style = True |

### Package Compatibility

| Status | Count | Percentage |
| :--- | :---: | :---: |
| ✅ Compatible | 2 | 100.0% |
| ⚠️ Incompatible | 0 | 0.0% |
| 🔄 Upgrade Recommended | 0 | 0.0% |
| ***Total NuGet Packages*** | ***2*** | ***100%*** |

### API Compatibility

| Category | Count | Impact |
| :--- | :---: | :--- |
| 🔴 Binary Incompatible | 0 | High - Require code changes |
| 🟡 Source Incompatible | 4 | Medium - Needs re-compilation and potential conflicting API error fixing |
| 🔵 Behavioral change | 15 | Low - Behavioral changes that may require testing at runtime |
| ✅ Compatible | 1806 |  |
| ***Total APIs Analyzed*** | ***1825*** |  |

## Aggregate NuGet packages details

| Package | Current Version | Suggested Version | Projects | Description |
| :--- | :---: | :---: | :--- | :--- |
| Microsoft.Windows.SDK.BuildTools | 10.0.28000.2526 |  | [MarkdownWin.csproj](#markdownwinmarkdownwincsproj) | ✅Compatible |
| Microsoft.WindowsAppSDK | 2.4.0 |  | [MarkdownWin.csproj](#markdownwinmarkdownwincsproj) | ✅Compatible |

## Top API Migration Challenges

### Technologies and Features

| Technology | Issues | Percentage | Migration Path |
| :--- | :---: | :---: | :--- |

### Most Frequent API Issues

| API | Count | Percentage | Category |
| :--- | :---: | :---: | :--- |
| T:System.Uri | 8 | 42.1% | Behavioral Change |
| M:System.Uri.#ctor(System.String) | 4 | 21.1% | Behavioral Change |
| T:Windows.UI.Color | 2 | 10.5% | Source Incompatible |
| M:System.Uri.TryCreate(System.String,System.UriKind,System.Uri@) | 2 | 10.5% | Behavioral Change |
| T:System.IO.WindowsRuntimeStreamExtensions | 1 | 5.3% | Source Incompatible |
| M:System.IO.WindowsRuntimeStreamExtensions.AsRandomAccessStream(System.IO.Stream) | 1 | 5.3% | Source Incompatible |
| P:System.Uri.AbsolutePath | 1 | 5.3% | Behavioral Change |

## Projects Relationship Graph

Legend:
📦 SDK-style project
⚙️ Classic project

```mermaid
flowchart LR
    P1["<b>📦&nbsp;MarkdownWin.csproj</b><br/><small>net8.0-windows10.0.19041.0</small>"]
    click P1 "#markdownwinmarkdownwincsproj"

```

## Project Details

<a id="markdownwinmarkdownwincsproj"></a>
### MarkdownWin\MarkdownWin.csproj

#### Project Info

- **Current Target Framework:** net8.0-windows10.0.19041.0
- **Proposed Target Framework:** net10.0-windows10.0.22000.0
- **SDK-style**: True
- **Project Kind:** WinForms
- **Dependencies**: 0
- **Dependants**: 0
- **Number of Files**: 22
- **Number of Files with Incidents**: 6
- **Lines of Code**: 894
- **Estimated LOC to modify**: 19+ (at least 2.1% of the project)

#### Dependency Graph

Legend:
📦 SDK-style project
⚙️ Classic project

```mermaid
flowchart TB
    subgraph current["MarkdownWin.csproj"]
        MAIN["<b>📦&nbsp;MarkdownWin.csproj</b><br/><small>net8.0-windows10.0.19041.0</small>"]
        click MAIN "#markdownwinmarkdownwincsproj"
    end

```

### API Compatibility

| Category | Count | Impact |
| :--- | :---: | :--- |
| 🔴 Binary Incompatible | 0 | High - Require code changes |
| 🟡 Source Incompatible | 4 | Medium - Needs re-compilation and potential conflicting API error fixing |
| 🔵 Behavioral change | 15 | Low - Behavioral changes that may require testing at runtime |
| ✅ Compatible | 1806 |  |
| ***Total APIs Analyzed*** | ***1825*** |  |

