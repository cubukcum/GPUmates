using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("GPUmates Coordinator")]
[assembly: AssemblyDescription("Starts and opens the local GPUmates Control Center")]
[assembly: AssemblyCompany("GPUmates")]
[assembly: AssemblyProduct("GPUmates Coordinator")]
[assembly: AssemblyVersion("0.3.0.0")]
[assembly: AssemblyFileVersion("0.3.0.0")]

namespace GPUmates.Coordinator.Launcher
{
    public static class Program
    {
        private const string HealthUrl = "http://127.0.0.1:8091/health";
        private const string ControlCenterUrl = "http://127.0.0.1:8091/";
        private const int ControlCenterPort = 8091;
        private const int StartupTimeoutMilliseconds = 15000;
        private const string StartupMutexName = @"Local\GPUmates.Coordinator.Launcher.Startup";
        private const string ControlCenterScriptRelativePath = @"scripts\Start-GPUmatesControlCenter.ps1";
        private const string ControlSessionRelativePath = @"GPUmates\Coordinator\control-session.dpapi";
        private const string ControlSessionHeader = "GPUmatesControlSessionV1";
        private const string ControlSessionEntropyText = "GPUmates Coordinator browser session schema 1";

        [STAThread]
        public static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            try
            {
                LaunchControlCenter();
            }
            catch (Exception exception)
            {
                ShowError(
                    "GPUmates Coordinator could not start.\r\n\r\n" +
                    exception.Message);
            }
        }

        private static void LaunchControlCenter()
        {
            string healthySessionId = GetHealthySessionId(600);
            if (healthySessionId != null)
            {
                OpenControlCenter(healthySessionId);
                return;
            }

            using (Mutex startupMutex = new Mutex(false, StartupMutexName))
            {
                bool ownsMutex = TryAcquireMutex(startupMutex);

                try
                {
                    if (!ownsMutex)
                    {
                        string waitingSessionId = WaitForHealthySession(StartupTimeoutMilliseconds);
                        if (waitingSessionId == null)
                        {
                            throw new InvalidOperationException(
                                "Another GPUmates launcher is starting the Control Center, but " +
                                HealthUrl + " did not become ready within 15 seconds.");
                        }

                        OpenControlCenter(waitingSessionId);
                        return;
                    }

                    // A second launcher may have completed startup just before this one
                    // acquired the mutex. Always probe again before creating a process.
                    healthySessionId = GetHealthySessionId(600);
                    if (healthySessionId != null)
                    {
                        OpenControlCenter(healthySessionId);
                        return;
                    }

                    bool portWasAlreadyInUse = IsControlCenterPortListening();
                    Process controlCenterProcess = null;

                    if (!portWasAlreadyInUse)
                    {
                        string projectRoot = FindProjectRoot();
                        if (projectRoot == null)
                        {
                            throw new FileNotFoundException(
                                "Could not find " + ControlCenterScriptRelativePath +
                                " by walking upward from:\r\n" + GetLauncherDirectory() +
                                "\r\n\r\nKeep GPUmates-Coordinator.exe inside the complete GPUmates project or coordinator package.");
                        }

                        controlCenterProcess = StartControlCenter(projectRoot);
                    }

                    string startedSessionId = WaitForHealthySession(StartupTimeoutMilliseconds);
                    if (startedSessionId == null)
                    {
                        if (portWasAlreadyInUse)
                        {
                            throw new InvalidOperationException(
                                "TCP port 8091 is already in use, but the GPUmates health check is unavailable at " +
                                HealthUrl + ".\r\n\r\nStop the conflicting or unresponsive process and try again.");
                        }

                        string processDetails = GetProcessFailureDetails(controlCenterProcess);
                        throw new TimeoutException(
                            "The GPUmates Control Center did not become ready at " + HealthUrl +
                            " within 15 seconds." + processDetails);
                    }

                    OpenControlCenter(startedSessionId);
                }
                finally
                {
                    if (ownsMutex)
                    {
                        try
                        {
                            startupMutex.ReleaseMutex();
                        }
                        catch (ApplicationException)
                        {
                            // The process is already exiting; there is nothing useful to recover here.
                        }
                    }
                }
            }
        }

        private static bool TryAcquireMutex(Mutex startupMutex)
        {
            try
            {
                return startupMutex.WaitOne(0, false);
            }
            catch (AbandonedMutexException)
            {
                // The previous launcher terminated during startup. This launcher now owns
                // the mutex and can safely re-check health before trying again.
                return true;
            }
        }

        private static string FindProjectRoot()
        {
            DirectoryInfo currentDirectory = new DirectoryInfo(GetLauncherDirectory());

            while (currentDirectory != null)
            {
                string candidate = Path.Combine(
                    currentDirectory.FullName,
                    ControlCenterScriptRelativePath);

                if (File.Exists(candidate))
                {
                    return currentDirectory.FullName;
                }

                currentDirectory = currentDirectory.Parent;
            }

            return null;
        }

        private static string GetLauncherDirectory()
        {
            string executablePath = Assembly.GetExecutingAssembly().Location;
            string launcherDirectory = Path.GetDirectoryName(executablePath);

            if (String.IsNullOrWhiteSpace(launcherDirectory))
            {
                throw new InvalidOperationException("Could not determine the launcher directory.");
            }

            return Path.GetFullPath(launcherDirectory);
        }

        private static Process StartControlCenter(string projectRoot)
        {
            string scriptPath = Path.Combine(projectRoot, ControlCenterScriptRelativePath);
            string windowsPowerShell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                @"System32\WindowsPowerShell\v1.0\powershell.exe");

            if (!File.Exists(windowsPowerShell))
            {
                throw new FileNotFoundException(
                    "Windows PowerShell was not found at the expected location.",
                    windowsPowerShell);
            }

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = windowsPowerShell;
            startInfo.Arguments =
                "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden " +
                "-ExecutionPolicy Bypass -File " + QuoteWindowsArgument(scriptPath);
            startInfo.WorkingDirectory = projectRoot;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.WindowStyle = ProcessWindowStyle.Hidden;
            startInfo.ErrorDialog = false;

            Process process = Process.Start(startInfo);
            if (process == null)
            {
                throw new InvalidOperationException("Windows could not create the Control Center process.");
            }

            return process;
        }

        private static string QuoteWindowsArgument(string value)
        {
            if (value == null)
            {
                throw new ArgumentNullException("value");
            }

            if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
            {
                return value;
            }

            StringBuilder quoted = new StringBuilder();
            quoted.Append('"');
            int backslashCount = 0;

            foreach (char character in value)
            {
                if (character == '\\')
                {
                    backslashCount++;
                    continue;
                }

                if (character == '"')
                {
                    quoted.Append('\\', (backslashCount * 2) + 1);
                    quoted.Append('"');
                    backslashCount = 0;
                    continue;
                }

                quoted.Append('\\', backslashCount);
                backslashCount = 0;
                quoted.Append(character);
            }

            // Backslashes immediately before the closing quote must be doubled.
            quoted.Append('\\', backslashCount * 2);
            quoted.Append('"');
            return quoted.ToString();
        }

        private static string GetHealthySessionId(int timeoutMilliseconds)
        {
            if (timeoutMilliseconds <= 0)
            {
                return null;
            }

            try
            {
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(HealthUrl);
                request.Method = "GET";
                request.Proxy = null;
                request.AllowAutoRedirect = false;
                request.KeepAlive = false;
                request.Timeout = timeoutMilliseconds;
                request.ReadWriteTimeout = timeoutMilliseconds;

                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                {
                    int statusCode = (int)response.StatusCode;
                    if (statusCode < 200 || statusCode >= 300)
                    {
                        return null;
                    }

                    using (StreamReader reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                    {
                        string body = reader.ReadToEnd();
                        Match match = Regex.Match(
                            body,
                            "\\\"sessionId\\\"\\s*:\\s*\\\"([0-9a-fA-F-]{36})\\\"");
                        Guid sessionId;
                        if (match.Success && Guid.TryParse(match.Groups[1].Value, out sessionId))
                        {
                            return sessionId.ToString("D");
                        }
                    }
                }
            }
            catch (WebException)
            {
                return null;
            }
            catch (IOException)
            {
                return null;
            }

            return null;
        }

        private static string WaitForHealthySession(int timeoutMilliseconds)
        {
            Stopwatch stopwatch = Stopwatch.StartNew();

            while (stopwatch.ElapsedMilliseconds < timeoutMilliseconds)
            {
                int remaining = timeoutMilliseconds - (int)stopwatch.ElapsedMilliseconds;
                int requestTimeout = Math.Min(600, remaining);

                string sessionId = GetHealthySessionId(requestTimeout);
                if (sessionId != null)
                {
                    return sessionId;
                }

                remaining = timeoutMilliseconds - (int)stopwatch.ElapsedMilliseconds;
                if (remaining > 0)
                {
                    Thread.Sleep(Math.Min(250, remaining));
                }
            }

            return null;
        }

        private static bool IsControlCenterPortListening()
        {
            try
            {
                IPEndPoint[] listeners = IPGlobalProperties
                    .GetIPGlobalProperties()
                    .GetActiveTcpListeners();

                foreach (IPEndPoint listener in listeners)
                {
                    if (listener.Port == ControlCenterPort)
                    {
                        return true;
                    }
                }
            }
            catch (NetworkInformationException)
            {
                // The health probe and startup mutex remain the primary safeguards.
            }

            return false;
        }

        private static string GetProcessFailureDetails(Process process)
        {
            if (process == null)
            {
                return String.Empty;
            }

            try
            {
                if (process.HasExited)
                {
                    return "\r\n\r\nThe hidden Windows PowerShell process exited with code " +
                        process.ExitCode + ".";
                }
            }
            catch (InvalidOperationException)
            {
                return String.Empty;
            }

            return "\r\n\r\nThe hidden Control Center process is still running but did not pass its health check.";
        }

        private static byte[] GetControlSessionEntropy()
        {
            using (SHA256 sha256 = SHA256.Create())
            {
                return sha256.ComputeHash(Encoding.UTF8.GetBytes(ControlSessionEntropyText));
            }
        }

        private static string ReadControlSessionToken(string expectedSessionId)
        {
            string localApplicationData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string sessionPath = Path.Combine(localApplicationData, ControlSessionRelativePath);
            return ReadControlSessionTokenFile(sessionPath, expectedSessionId);
        }

        private static string ReadControlSessionTokenFile(string sessionPath, string expectedSessionId)
        {
            if (!File.Exists(sessionPath))
            {
                throw new InvalidOperationException(
                    "The local browser-session token is unavailable for this Windows user.\r\n\r\n" +
                    "If another Windows account is running GPUmates Coordinator, close it there first.");
            }

            string[] lines = File.ReadAllLines(sessionPath, Encoding.UTF8);
            if (lines.Length != 4 || lines[0] != ControlSessionHeader)
            {
                throw new InvalidDataException("The GPUmates browser-session file has an unsupported format.");
            }
            Guid storedSessionId;
            if (!Guid.TryParse(lines[1], out storedSessionId) ||
                !String.Equals(storedSessionId.ToString("D"), expectedSessionId, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException(
                    "The local browser-session file does not belong to the running GPUmates Control Center.");
            }

            DataProtectionScope scope;
            if (lines[2] == "CurrentUser")
            {
                scope = DataProtectionScope.CurrentUser;
            }
            else if (lines[2] == "LocalMachineAcl")
            {
                scope = DataProtectionScope.LocalMachine;
            }
            else
            {
                throw new InvalidDataException("The GPUmates browser-session protection scope is unsupported.");
            }

            byte[] protectedBytes;
            try
            {
                protectedBytes = Convert.FromBase64String(lines[3]);
            }
            catch (FormatException exception)
            {
                throw new InvalidDataException("The GPUmates browser-session token is malformed.", exception);
            }

            byte[] clearBytes = null;
            try
            {
                clearBytes = ProtectedData.Unprotect(protectedBytes, GetControlSessionEntropy(), scope);
                string token = Encoding.UTF8.GetString(clearBytes);
                if (token.Length < 24)
                {
                    throw new InvalidDataException("The GPUmates browser-session token is invalid.");
                }
                return token;
            }
            catch (CryptographicException exception)
            {
                throw new InvalidOperationException(
                    "Windows could not unlock the GPUmates browser session for this user.",
                    exception);
            }
            finally
            {
                Array.Clear(protectedBytes, 0, protectedBytes.Length);
                if (clearBytes != null)
                {
                    Array.Clear(clearBytes, 0, clearBytes.Length);
                }
            }
        }

        private static void OpenControlCenter(string sessionId)
        {
            string controlToken = ReadControlSessionToken(sessionId);
            try
            {
                ProcessStartInfo browserStartInfo = new ProcessStartInfo();
                browserStartInfo.FileName = ControlCenterUrl + "#token=" + Uri.EscapeDataString(controlToken);
                browserStartInfo.UseShellExecute = true;
                Process.Start(browserStartInfo);
            }
            catch (Exception exception)
            {
                throw new InvalidOperationException(
                    "The Control Center is ready, but Windows could not open the default browser.\r\n\r\n" +
                    "Open this address manually: " + ControlCenterUrl + "\r\n\r\n" +
                    "Details: " + exception.Message,
                    exception);
            }
            finally
            {
                controlToken = null;
            }
        }

        private static void ShowError(string message)
        {
            MessageBox.Show(
                message,
                "GPUmates Coordinator",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error,
                MessageBoxDefaultButton.Button1,
                MessageBoxOptions.ServiceNotification);
        }
    }
}
