using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace YouTubeCookieBridge
{
    internal static class Program
    {
        private const string HostName = "com.youtube_audio_downloader.cookie_bridge";
        private const string DefaultExtensionId = "fijankghajiibgecbhcplneaebaijgma";
        private const int MaxNativeMessageBytes = 16 * 1024 * 1024;
        private static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = MaxNativeMessageBytes };

        private sealed class BridgePaths
        {
            public string Root;
            public string AuthDirectory;
            public string CookieFile;
            public string RequestFile;
            public string RequestClaimFile;
            public string ResultFile;
            public string ConfigFile;
            public string HostManifestFile;
        }

        private sealed class CookieRecord
        {
            public string Domain;
            public bool IncludeSubdomains;
            public string Path;
            public bool Secure;
            public bool HttpOnly;
            public long Expires;
            public string Name;
            public string Value;
        }

        public static int Main(string[] args)
        {
            bool nativeMode = args.Length > 0 && args[0].StartsWith("chrome-extension://", StringComparison.OrdinalIgnoreCase);
            try
            {
                if (nativeMode)
                    return RunNativeHost(args);
                if (args.Length == 0)
                {
                    PrintHelp();
                    return 1;
                }

                string command = args[0].ToLowerInvariant();
                if (command == "install") return Install(args.Skip(1).ToArray());
                if (command == "export") return Export(args.Skip(1).ToArray());
                if (command == "validate") return Validate(args.Skip(1).ToArray());
                if (command == "status") return Status();
                if (command == "self-test") return SelfTest();
                PrintHelp();
                return 1;
            }
            catch (Exception ex)
            {
                if (nativeMode)
                    Console.Error.WriteLine("Cookie bridge host failed: " + SafeError(ex));
                else
                    Console.Error.WriteLine("Cookie export failed: " + SafeError(ex));
                return 1;
            }
        }

        private static void PrintHelp()
        {
            Console.WriteLine("YouTube Cookie Bridge prototype");
            Console.WriteLine("  cookie-bridge install [--extension-id ID]");
            Console.WriteLine("  cookie-bridge export [--timeout 120]");
            Console.WriteLine("  cookie-bridge validate --url URL [--yt-dlp PATH] [--require-premium]");
            Console.WriteLine("  cookie-bridge status");
            Console.WriteLine("  cookie-bridge self-test");
        }

        private static BridgePaths GetPaths()
        {
            string root = Environment.GetEnvironmentVariable("COOKIE_BRIDGE_ROOT");
            if (String.IsNullOrWhiteSpace(root))
            {
                string[] starts = { AppDomain.CurrentDomain.BaseDirectory, Environment.CurrentDirectory };
                foreach (string start in starts)
                {
                    DirectoryInfo current = new DirectoryInfo(Path.GetFullPath(start));
                    while (current != null)
                    {
                        if (File.Exists(Path.Combine(current.FullName, "YoutubeAudioDownloader.ps1")))
                        {
                            root = current.FullName;
                            break;
                        }
                        current = current.Parent;
                    }
                    if (!String.IsNullOrWhiteSpace(root)) break;
                }
            }
            if (String.IsNullOrWhiteSpace(root))
                throw new InvalidOperationException("Cannot locate the project root. Set COOKIE_BRIDGE_ROOT.");

            string auth = Path.Combine(Path.GetFullPath(root), "data", "auth");
            return new BridgePaths
            {
                Root = Path.GetFullPath(root),
                AuthDirectory = auth,
                CookieFile = Path.Combine(auth, "youtube.cookies.txt"),
                RequestFile = Path.Combine(auth, "cookie-export-request.json"),
                RequestClaimFile = Path.Combine(auth, "cookie-export-request.processing.json"),
                ResultFile = Path.Combine(auth, "cookie-export-result.json"),
                ConfigFile = Path.Combine(auth, "cookie-bridge-config.json"),
                HostManifestFile = Path.Combine(auth, HostName + ".json")
            };
        }

        private static int Install(string[] args)
        {
            BridgePaths paths = GetPaths();
            string extensionId = GetOption(args, "--extension-id", DefaultExtensionId).ToLowerInvariant();
            if (!IsValidExtensionId(extensionId))
                throw new ArgumentException("Extension ID must contain exactly 32 letters from a through p.");

            string executable = Process.GetCurrentProcess().MainModule.FileName;
            if (!String.Equals(Path.GetExtension(executable), ".exe", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(Path.GetFileName(executable), "powershell.exe", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Run install from the compiled cookie-bridge.exe produced by build.ps1.");

            EnsureSecureDirectory(paths.AuthDirectory);
            WriteJsonAtomic(paths.ConfigFile, new Dictionary<string, object>
            {
                { "extensionId", extensionId },
                { "installedUtc", DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) }
            });
            WriteJsonAtomic(paths.HostManifestFile, new Dictionary<string, object>
            {
                { "name", HostName },
                { "description", "YouTube Cookie Bridge native messaging host" },
                { "path", executable },
                { "type", "stdio" },
                { "allowed_origins", new object[] { "chrome-extension://" + extensionId + "/" } }
            });

            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(@"Software\Google\Chrome\NativeMessagingHosts\" + HostName))
                key.SetValue(null, paths.HostManifestFile, RegistryValueKind.String);

            Console.WriteLine("Cookie Bridge installed");
            Console.WriteLine("Extension ID: " + extensionId);
            Console.WriteLine("Native host: registered for current Windows user");
            return 0;
        }

        private static int Export(string[] args)
        {
            BridgePaths paths = GetPaths();
            Dictionary<string, object> config = ReadJson(paths.ConfigFile);
            string extensionId = GetString(config, "extensionId");
            if (!IsValidExtensionId(extensionId))
                throw new InvalidOperationException("Cookie Bridge is not installed. Run cookie-bridge install first.");

            int timeoutSeconds;
            if (!Int32.TryParse(GetOption(args, "--timeout", "120"), out timeoutSeconds) || timeoutSeconds < 10 || timeoutSeconds > 600)
                throw new ArgumentException("--timeout must be between 10 and 600 seconds.");

            EnsureSecureDirectory(paths.AuthDirectory);
            SafeDelete(paths.CookieFile);
            SafeDelete(paths.RequestFile);
            SafeDelete(paths.RequestClaimFile);
            SafeDelete(paths.ResultFile);

            string requestId = Guid.NewGuid().ToString("N") + Guid.NewGuid().ToString("N");
            DateTime expires = DateTime.UtcNow.AddSeconds(timeoutSeconds);
            WriteJsonAtomic(paths.RequestFile, new Dictionary<string, object>
            {
                { "requestId", requestId },
                { "createdUtc", DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) },
                { "expiresUtc", expires.ToString("o", CultureInfo.InvariantCulture) }
            });
            Console.WriteLine("Cookie export pending");

            while (DateTime.UtcNow < expires)
            {
                Thread.Sleep(500);
                Dictionary<string, object> result = TryReadJson(paths.ResultFile);
                if (result == null || !String.Equals(GetString(result, "requestId"), requestId, StringComparison.Ordinal))
                    continue;

                bool success = GetBoolean(result, "success");
                SafeDelete(paths.ResultFile);
                SafeDelete(paths.RequestFile);
                SafeDelete(paths.RequestClaimFile);
                if (success && IsValidCookieFile(paths.CookieFile))
                {
                    Console.WriteLine("Cookie export successful");
                    Console.WriteLine("Cookie file: " + paths.CookieFile);
                    return 0;
                }
                SafeDelete(paths.CookieFile);
                Console.Error.WriteLine("Cookie export failed: " + GetSafeResultMessage(result));
                return 2;
            }

            SafeDelete(paths.RequestFile);
            SafeDelete(paths.RequestClaimFile);
            SafeDelete(paths.ResultFile);
            SafeDelete(paths.CookieFile);
            Console.Error.WriteLine("Cookie export failed: timed out waiting for Chrome extension");
            return 2;
        }

        private static int Validate(string[] args)
        {
            BridgePaths paths = GetPaths();
            string url = GetOption(args, "--url", null);
            if (String.IsNullOrWhiteSpace(url))
                throw new ArgumentException("validate requires --url.");
            if (!IsValidCookieFile(paths.CookieFile))
            {
                Console.Error.WriteLine("Premium validation failed: cookie export is missing");
                return 3;
            }

            string ytDlp = GetOption(args, "--yt-dlp", Path.Combine(paths.Root, "tools", "yt-dlp.exe"));
            if (!File.Exists(ytDlp))
                throw new FileNotFoundException("yt-dlp executable was not found.", ytDlp);

            List<string> commandArgs = new List<string>
            {
                "-J", "-v", "--skip-download", "--no-playlist", "--cookies", paths.CookieFile
            };
            string deno = Path.Combine(paths.Root, "tools", "deno.exe");
            if (File.Exists(deno))
            {
                commandArgs.Add("--js-runtimes");
                commandArgs.Add("deno:" + deno);
            }
            commandArgs.Add(url);

            ProcessStartInfo psi = new ProcessStartInfo
            {
                FileName = ytDlp,
                Arguments = String.Join(" ", commandArgs.Select(QuoteArgument).ToArray()),
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            string stdout;
            string stderr;
            int exitCode;
            using (Process process = Process.Start(psi))
            {
                stdout = "";
                stderr = "";
                Thread stdoutReader = new Thread(() => { stdout = process.StandardOutput.ReadToEnd(); });
                Thread stderrReader = new Thread(() => { stderr = process.StandardError.ReadToEnd(); });
                stdoutReader.Start();
                stderrReader.Start();
                if (!process.WaitForExit(120000))
                {
                    try { process.Kill(); } catch { }
                    stdoutReader.Join(5000);
                    stderrReader.Join(5000);
                    Console.WriteLine("Authentication validation failed");
                    Console.WriteLine("Premium validation failed");
                    Console.Error.WriteLine("Premium validation failed: yt-dlp probe timed out");
                    return 6;
                }
                stdoutReader.Join();
                stderrReader.Join();
                exitCode = process.ExitCode;
            }
            string diagnostic = stdout + "\n" + stderr;
            bool account = diagnostic.IndexOf("Found YouTube account cookies", StringComparison.OrdinalIgnoreCase) >= 0;
            bool premium = diagnostic.IndexOf("Detected YouTube Premium subscription", StringComparison.OrdinalIgnoreCase) >= 0;
            bool requirePremium = HasFlag(args, "--require-premium");

            Console.WriteLine(account && exitCode == 0 ? "Authentication validation successful" : "Authentication validation failed");
            Console.WriteLine(premium && exitCode == 0 ? "Premium validation successful" : "Premium validation failed");
            if (exitCode != 0 || !account || (requirePremium && !premium)) return 4;
            return 0;
        }

        private static int Status()
        {
            BridgePaths paths = GetPaths();
            Console.WriteLine(File.Exists(paths.ConfigFile) ? "Native host configuration: present" : "Native host configuration: missing");
            Console.WriteLine(IsValidCookieFile(paths.CookieFile) ? "Cookie export: present" : "Cookie export: missing");
            if (File.Exists(paths.CookieFile))
                Console.WriteLine("Cookie file updated: " + File.GetLastWriteTime(paths.CookieFile).ToString("yyyy-MM-dd HH:mm:ss"));
            return 0;
        }

        private static int RunNativeHost(string[] args)
        {
            BridgePaths paths = GetPaths();
            try
            {
                Dictionary<string, object> config = ReadJson(paths.ConfigFile);
                string expectedOrigin = "chrome-extension://" + GetString(config, "extensionId") + "/";
                if (!String.Equals(args[0], expectedOrigin, StringComparison.OrdinalIgnoreCase))
                {
                    WriteNativeMessage(new Dictionary<string, object> { { "type", "result" }, { "success", false }, { "message", "extension origin rejected" } });
                    return 5;
                }

                Dictionary<string, object> hello = ReadNativeMessage();
                if (hello == null || !String.Equals(GetString(hello, "type"), "hello", StringComparison.Ordinal))
                    throw new InvalidDataException("Expected extension hello message.");

                if (!File.Exists(paths.RequestFile))
                {
                    WriteNativeMessage(new Dictionary<string, object> { { "type", "no_request" } });
                    return 0;
                }
                try
                {
                    File.Move(paths.RequestFile, paths.RequestClaimFile);
                }
                catch (IOException)
                {
                    WriteNativeMessage(new Dictionary<string, object> { { "type", "no_request" } });
                    return 0;
                }
                Dictionary<string, object> request = ReadJson(paths.RequestClaimFile);
                string requestId = GetString(request, "requestId");
                DateTime expiresUtc;
                if (requestId.Length != 64 || !DateTime.TryParse(GetString(request, "expiresUtc"), null, DateTimeStyles.RoundtripKind, out expiresUtc) || expiresUtc.ToUniversalTime() <= DateTime.UtcNow)
                {
                    SafeDelete(paths.RequestClaimFile);
                    SafeDelete(paths.CookieFile);
                    WriteNativeMessage(new Dictionary<string, object> { { "type", "result" }, { "success", false }, { "message", "export request expired" } });
                    return 6;
                }

                WriteNativeMessage(new Dictionary<string, object> { { "type", "export_request" }, { "requestId", requestId } });
                Dictionary<string, object> export = ReadNativeMessage();
                if (export == null || !String.Equals(GetString(export, "type"), "cookie_export", StringComparison.Ordinal) ||
                    !String.Equals(GetString(export, "requestId"), requestId, StringComparison.Ordinal))
                    throw new InvalidDataException("Cookie export response did not match the one-time request.");

                object rawCookies;
                if (!export.TryGetValue("cookies", out rawCookies))
                    throw new InvalidDataException("Cookie export did not include cookies.");
                int written = WriteNetscapeCookieFile(paths.CookieFile, AsObjectSequence(rawCookies));
                if (written == 0)
                    throw new InvalidDataException("No allowed YouTube or Google cookies were received.");

                WriteJsonAtomic(paths.ResultFile, new Dictionary<string, object>
                {
                    { "requestId", requestId }, { "success", true }, { "cookieCount", written }, { "message", "ok" }
                });
                SafeDelete(paths.RequestClaimFile);
                WriteNativeMessage(new Dictionary<string, object> { { "type", "result" }, { "success", true }, { "cookieCount", written } });
                return 0;
            }
            catch (Exception ex)
            {
                TryDelete(paths.CookieFile);
                Dictionary<string, object> request = TryReadJson(paths.RequestClaimFile) ?? TryReadJson(paths.RequestFile);
                string requestId = request == null ? "" : GetString(request, "requestId");
                if (!String.IsNullOrEmpty(requestId))
                {
                    WriteJsonAtomic(paths.ResultFile, new Dictionary<string, object>
                    {
                        { "requestId", requestId }, { "success", false }, { "message", SafeError(ex) }
                    });
                }
                TryDelete(paths.RequestFile);
                TryDelete(paths.RequestClaimFile);
                try { WriteNativeMessage(new Dictionary<string, object> { { "type", "result" }, { "success", false }, { "message", "cookie export failed" } }); }
                catch { }
                return 7;
            }
        }

        private static int WriteNetscapeCookieFile(string path, IEnumerable<object> rawCookies)
        {
            List<CookieRecord> cookies = new List<CookieRecord>();
            foreach (object raw in rawCookies.Take(2000))
            {
                Dictionary<string, object> item = raw as Dictionary<string, object>;
                if (item == null) continue;
                string domain = GetString(item, "domain").Trim().ToLowerInvariant();
                string name = GetString(item, "name");
                string value = GetString(item, "value");
                string cookiePath = GetString(item, "path");
                if (!IsAllowedCookieDomain(domain) || HasUnsafeField(domain) || HasUnsafeField(name) || HasUnsafeField(value) || HasUnsafeField(cookiePath))
                    continue;
                if (String.IsNullOrEmpty(name)) continue;
                if (String.IsNullOrEmpty(cookiePath)) cookiePath = "/";
                long expires = 0;
                object expirationValue;
                if (item.TryGetValue("expirationDate", out expirationValue) && expirationValue != null)
                {
                    double numeric;
                    if (Double.TryParse(Convert.ToString(expirationValue, CultureInfo.InvariantCulture), NumberStyles.Any, CultureInfo.InvariantCulture, out numeric))
                        expires = Convert.ToInt64(Math.Floor(numeric));
                }
                cookies.Add(new CookieRecord
                {
                    Domain = domain,
                    IncludeSubdomains = domain.StartsWith(".", StringComparison.Ordinal),
                    Path = cookiePath,
                    Secure = GetBoolean(item, "secure"),
                    HttpOnly = GetBoolean(item, "httpOnly"),
                    Expires = expires,
                    Name = name,
                    Value = value
                });
            }

            List<CookieRecord> unique = cookies
                .GroupBy(c => c.Domain + "\n" + c.Path + "\n" + c.Name, StringComparer.Ordinal)
                .Select(group => group.Last())
                .OrderBy(c => c.Domain, StringComparer.Ordinal)
                .ThenBy(c => c.Path, StringComparer.Ordinal)
                .ThenBy(c => c.Name, StringComparer.Ordinal)
                .ToList();

            StringBuilder text = new StringBuilder();
            text.Append("# Netscape HTTP Cookie File\r\n");
            text.Append("# Generated locally by YouTube Cookie Bridge. Do not share this file.\r\n");
            foreach (CookieRecord cookie in unique)
            {
                string outputDomain = cookie.HttpOnly ? "#HttpOnly_" + cookie.Domain : cookie.Domain;
                text.Append(outputDomain).Append('\t')
                    .Append(cookie.IncludeSubdomains ? "TRUE" : "FALSE").Append('\t')
                    .Append(cookie.Path).Append('\t')
                    .Append(cookie.Secure ? "TRUE" : "FALSE").Append('\t')
                    .Append(cookie.Expires.ToString(CultureInfo.InvariantCulture)).Append('\t')
                    .Append(cookie.Name).Append('\t')
                    .Append(cookie.Value).Append("\r\n");
            }
            if (unique.Count == 0) return 0;
            WriteTextAtomic(path, text.ToString());
            return unique.Count;
        }

        private static bool IsAllowedCookieDomain(string domain)
        {
            return domain == ".youtube.com" || domain == "youtube.com" ||
                   domain == "www.youtube.com" || domain == "music.youtube.com" ||
                   domain == ".google.com" || domain == "google.com" ||
                   domain == "accounts.google.com";
        }

        private static bool HasUnsafeField(string value)
        {
            return value == null || value.IndexOfAny(new[] { '\r', '\n', '\t' }) >= 0;
        }

        private static bool IsValidCookieFile(string path)
        {
            if (!File.Exists(path)) return false;
            using (StreamReader reader = new StreamReader(path, Encoding.UTF8, true))
            {
                if (!String.Equals(reader.ReadLine(), "# Netscape HTTP Cookie File", StringComparison.Ordinal)) return false;
                string line;
                while ((line = reader.ReadLine()) != null)
                    if (line.StartsWith("#HttpOnly_", StringComparison.Ordinal) ||
                        (line.Length > 0 && !line.StartsWith("#", StringComparison.Ordinal))) return true;
            }
            return false;
        }

        private static int SelfTest()
        {
            string directory = Path.Combine(Path.GetTempPath(), "youtube-cookie-bridge-test-" + Guid.NewGuid().ToString("N"));
            string output = Path.Combine(directory, "youtube.cookies.txt");
            Directory.CreateDirectory(directory);
            try
            {
                object[] cookies =
                {
                    NewTestCookie(".youtube.com", "YT_TEST", true, false),
                    NewTestCookie(".google.com", "GOOGLE_TEST", true, true),
                    NewTestCookie("example.com", "REJECT_TEST", false, false)
                };
                int count = WriteNetscapeCookieFile(output, cookies);
                byte[] bytes = File.ReadAllBytes(output);
                string content = new UTF8Encoding(false).GetString(bytes);
                bool crlfOnly = !content.Replace("\r\n", "").Contains("\n");
                bool rejected = content.IndexOf("REJECT_TEST", StringComparison.Ordinal) < 0;
                if (count != 2 || !IsValidCookieFile(output) || !crlfOnly || !rejected)
                    throw new InvalidDataException("Netscape cookie writer self-test failed.");
                Console.WriteLine("Cookie Bridge self-test successful");
                return 0;
            }
            finally
            {
                try { Directory.Delete(directory, true); } catch { }
            }
        }

        private static Dictionary<string, object> NewTestCookie(string domain, string name, bool secure, bool httpOnly)
        {
            return new Dictionary<string, object>
            {
                { "domain", domain }, { "path", "/" }, { "secure", secure }, { "httpOnly", httpOnly },
                { "expirationDate", 2000000000d }, { "name", name }, { "value", "synthetic-value" }
            };
        }

        private static Dictionary<string, object> ReadNativeMessage()
        {
            Stream input = Console.OpenStandardInput();
            byte[] lengthBytes = ReadExactly(input, 4);
            if (lengthBytes == null) return null;
            int length = BitConverter.ToInt32(lengthBytes, 0);
            if (length <= 0 || length > MaxNativeMessageBytes) throw new InvalidDataException("Native message length is invalid.");
            byte[] payload = ReadExactly(input, length);
            if (payload == null) throw new EndOfStreamException("Native message ended unexpectedly.");
            return Json.Deserialize<Dictionary<string, object>>(Encoding.UTF8.GetString(payload));
        }

        private static void WriteNativeMessage(object message)
        {
            byte[] payload = Encoding.UTF8.GetBytes(Json.Serialize(message));
            if (payload.Length > 1024 * 1024) throw new InvalidDataException("Native response exceeds Chrome's limit.");
            Stream output = Console.OpenStandardOutput();
            byte[] length = BitConverter.GetBytes(payload.Length);
            output.Write(length, 0, length.Length);
            output.Write(payload, 0, payload.Length);
            output.Flush();
        }

        private static byte[] ReadExactly(Stream stream, int count)
        {
            byte[] buffer = new byte[count];
            int offset = 0;
            while (offset < count)
            {
                int read = stream.Read(buffer, offset, count - offset);
                if (read == 0)
                {
                    if (offset == 0) return null;
                    throw new EndOfStreamException("Native message ended unexpectedly.");
                }
                offset += read;
            }
            return buffer;
        }

        private static IEnumerable<object> AsObjectSequence(object value)
        {
            object[] array = value as object[];
            if (array != null) return array;
            ArrayList list = value as ArrayList;
            if (list != null) return list.Cast<object>();
            return Enumerable.Empty<object>();
        }

        private static Dictionary<string, object> ReadJson(string path)
        {
            if (!File.Exists(path)) throw new FileNotFoundException("Required Cookie Bridge state is missing.", path);
            return Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(path, Encoding.UTF8));
        }

        private static Dictionary<string, object> TryReadJson(string path)
        {
            try { return File.Exists(path) ? ReadJson(path) : null; }
            catch { return null; }
        }

        private static void WriteJsonAtomic(string path, object value)
        {
            WriteTextAtomic(path, Json.Serialize(value));
        }

        private static void WriteTextAtomic(string path, string content)
        {
            EnsureSecureDirectory(Path.GetDirectoryName(path));
            string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            File.WriteAllText(temporary, content, new UTF8Encoding(false));
            ApplyUserOnlyAcl(temporary, false);
            if (File.Exists(path)) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
            ApplyUserOnlyAcl(path, false);
        }

        private static void EnsureSecureDirectory(string path)
        {
            Directory.CreateDirectory(path);
            ApplyUserOnlyAcl(path, true);
        }

        private static void ApplyUserOnlyAcl(string path, bool directory)
        {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT) return;
            string sid = WindowsIdentity.GetCurrent().User.Value;
            string permission = directory ? "(OI)(CI)F" : "F";
            ProcessStartInfo psi = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, "icacls.exe"),
                Arguments = QuoteArgument(path) + " /inheritance:r /grant:r \"*" + sid + ":" + permission + "\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (Process process = Process.Start(psi))
            {
                process.StandardOutput.ReadToEnd();
                process.StandardError.ReadToEnd();
                process.WaitForExit();
                if (process.ExitCode != 0) throw new UnauthorizedAccessException("Unable to apply user-only permissions to Cookie Bridge state.");
            }
        }

        private static string GetOption(string[] args, string name, string defaultValue)
        {
            for (int index = 0; index < args.Length - 1; index++)
                if (String.Equals(args[index], name, StringComparison.OrdinalIgnoreCase)) return args[index + 1];
            return defaultValue;
        }

        private static bool HasFlag(string[] args, string name)
        {
            return args.Any(value => String.Equals(value, name, StringComparison.OrdinalIgnoreCase));
        }

        private static string GetString(Dictionary<string, object> value, string key)
        {
            object raw;
            return value != null && value.TryGetValue(key, out raw) && raw != null ? Convert.ToString(raw, CultureInfo.InvariantCulture) : "";
        }

        private static bool GetBoolean(Dictionary<string, object> value, string key)
        {
            object raw;
            if (value == null || !value.TryGetValue(key, out raw) || raw == null) return false;
            bool parsed;
            return Boolean.TryParse(Convert.ToString(raw, CultureInfo.InvariantCulture), out parsed) && parsed;
        }

        private static bool IsValidExtensionId(string value)
        {
            return !String.IsNullOrEmpty(value) && value.Length == 32 && value.All(character => character >= 'a' && character <= 'p');
        }

        private static string GetSafeResultMessage(Dictionary<string, object> result)
        {
            string message = GetString(result, "message");
            return String.IsNullOrWhiteSpace(message) ? "native host rejected the export" : message;
        }

        private static string SafeError(Exception ex)
        {
            if (ex is FileNotFoundException) return "required local file is missing";
            if (ex is UnauthorizedAccessException) return "local permission check failed";
            if (ex is InvalidDataException || ex is InvalidOperationException || ex is ArgumentException) return ex.Message;
            return ex.GetType().Name;
        }

        private static string QuoteArgument(string value)
        {
            if (value == null) return "\"\"";
            if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0) return value;
            StringBuilder quoted = new StringBuilder("\"");
            int backslashes = 0;
            foreach (char character in value)
            {
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (character == '"')
                {
                    quoted.Append('\\', backslashes * 2 + 1).Append(character);
                    backslashes = 0;
                    continue;
                }
                quoted.Append('\\', backslashes).Append(character);
                backslashes = 0;
            }
            quoted.Append('\\', backslashes * 2).Append('"');
            return quoted.ToString();
        }

        private static void SafeDelete(string path)
        {
            try { if (File.Exists(path)) File.Delete(path); }
            catch { throw new IOException("Unable to remove stale Cookie Bridge state."); }
        }

        private static void TryDelete(string path)
        {
            try { if (File.Exists(path)) File.Delete(path); }
            catch { }
        }
    }
}
