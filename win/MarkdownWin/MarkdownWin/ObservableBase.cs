//
//  ObservableBase.cs
//  MarkdownWin
//
//  Shared INotifyPropertyChanged boilerplate, factored out so it isn't duplicated across
//  Workspace and Account.
//

using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace MarkdownWin;

internal abstract class ObservableBase : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (Equals(field, value))
        {
            return false;
        }

        field = value;
        Notify(propertyName);
        return true;
    }

    protected void Notify([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}
