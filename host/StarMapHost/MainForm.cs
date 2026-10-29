using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Text.Json;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace StarMapHost;

public sealed class MainForm : Form
{
    private readonly WebView2 _webView = new() { Dock = DockStyle.Fill };
    private const string ShortcutFileName = "StarMap-For-git.lnk";
    private const string AppDisplayName = "StarMap-For-git";

    public MainForm()
    {
        Text = AppDisplayName;
        Width = 1280;
        Height = 800;
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(800, 600);
        BackColor = Color.FromArgb(11, 11, 11);
        Controls.Add(_webView);
        Load += async (_, _) => await InitWebViewAsync();
    }

    private async System.Threading.Tasks.Task InitWebViewAsync()
    {
        try
        {
            var userData = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "StarMap-For-git", "WebView2");
            Directory.CreateDirectory(userData);
            var env = await CoreWebView2Environment.CreateAsync(userDataFolder: userData);
            await _webView.EnsureCoreWebView2Async(env);

            _webView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = true;
            _webView.CoreWebView2.Settings.AreDevToolsEnabled = true;
            _webView.CoreWebView2.Settings.IsStatusBarEnabled = false;
            _webView.CoreWebView2.WebMessageReceived += OnWebMessageReceived;

            var index = ResolveIndexHtml();
            if (index == null)
            {
                _webView.CoreWebView2.NavigateToString(
                    "<html><body style='background:#0b0b0b;color:#fff;font-family:sans-serif;padding:2rem'>" +
                    "<h1>StarMap-For-git</h1><p>Missing www/index.html</p></body></html>");
                return;
            }

            _webView.CoreWebView2.SetVirtualHostNameToFolderMapping(
                "app.starmap.local",
                Path.GetDirectoryName(index)!,
                CoreWebView2HostResourceAccessKind.Allow);
            _webView.CoreWebView2.Navigate("https://app.starmap.local/index.html");

            _webView.CoreWebView2.NavigationCompleted += (_, args) =>
            {
                if (!args.IsSuccess) return;
                try
                {
                    var exists = File.Exists(GetDesktopShortcutPath());
                    PostToJs(new { type = "shortcutStatus", exists });
                }
                catch { /* ignore */ }
            };
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "WebView2 init failed:\n" + ex.Message, AppDisplayName,
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private static string? ResolveIndexHtml()
    {
        var baseDir = AppContext.BaseDirectory;
        var candidates = new[]
        {
            Path.Combine(baseDir, "www", "index.html"),
            Path.Combine(baseDir, "index.html"),
            Path.Combine(Directory.GetCurrentDirectory(), "www", "index.html"),
        };
        foreach (var c in candidates)
        {
            if (File.Exists(c)) return Path.GetFullPath(c);
        }
        return null;
    }

    private void OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        string raw;
        try { raw = e.TryGetWebMessageAsString(); }
        catch { raw = e.WebMessageAsJson; }

        if (string.IsNullOrWhiteSpace(raw)) return;

        string? type = null;
        try
        {
            using var doc = JsonDocument.Parse(raw);
            if (doc.RootElement.TryGetProperty("type", out var t))
                type = t.GetString();
        }
        catch
        {
            type = raw.Trim().Trim('"');
        }

        if (string.Equals(type, "openAppsFolder", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(type, "createDesktopShortcut", StringComparison.OrdinalIgnoreCase))
        {
            // Preferred UX: open shell:AppsFolder so user can drag the app to Desktop.
            var ok = TryOpenAppsFolder(out var err);
            PostToJs(new { type = "appsFolderOpened", ok, error = err });
            // Also ack legacy shortcutCreated so older SPA handlers settle.
            if (string.Equals(type, "createDesktopShortcut", StringComparison.OrdinalIgnoreCase))
                PostToJs(new { type = "shortcutCreated", ok, error = err });
        }
    }

    private void PostToJs(object payload)
    {
        try
        {
            var json = JsonSerializer.Serialize(payload);
            _webView.CoreWebView2?.PostWebMessageAsJson(json);
        }
        catch { /* ignore */ }
    }

    private static string GetDesktopShortcutPath()
    {
        var desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        return Path.Combine(desktop, ShortcutFileName);
    }

    private static bool TryOpenAppsFolder(out string? error)
    {
        error = null;
        try
        {
            // Prefer highlighting this app in AppsFolder when packaged.
            var pfn = GetPackageFamilyName();
            var psi = new ProcessStartInfo
            {
                FileName = "explorer.exe",
                UseShellExecute = true,
            };
            if (!string.IsNullOrEmpty(pfn))
            {
                // Opens AppsFolder; user can drag StarMap-For-git to Desktop.
                // shell:AppsFolder\PFN!App focuses the app entry when possible.
                psi.Arguments = $"shell:AppsFolder\\{pfn}!App";
            }
            else
            {
                psi.Arguments = "shell:AppsFolder";
            }

            Process.Start(psi);
            return true;
        }
        catch (Exception ex)
        {
            // Fallback: bare AppsFolder
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = "shell:AppsFolder",
                    UseShellExecute = true,
                });
                return true;
            }
            catch (Exception ex2)
            {
                error = ex.Message + " | " + ex2.Message;
                return false;
            }
        }
    }

    private static string? GetPackageFamilyName()
    {
        try
        {
            int len = 0;
            var hr = GetCurrentPackageFamilyName(ref len, null);
            // APPMODEL_ERROR_NO_PACKAGE = 15700
            if (hr == 15700 || len <= 1) return null;
            var sb = new StringBuilder(len);
            hr = GetCurrentPackageFamilyName(ref len, sb);
            if (hr != 0) return null;
            var name = sb.ToString();
            return string.IsNullOrWhiteSpace(name) ? null : name;
        }
        catch
        {
            return null;
        }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int GetCurrentPackageFamilyName(ref int packageFamilyNameLength, StringBuilder? packageFamilyName);
}
