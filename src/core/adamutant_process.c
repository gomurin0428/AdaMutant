/*  Process spawning for AdaMutant.
 *
 *  Runs a shell command in a directory, redirects stdout and stderr to a log
 *  file, enforces a timeout and kills the whole process tree afterwards
 *  (process group on POSIX, job object on Windows), so test runners that
 *  start helper processes cannot leak them or keep a sandbox busy.  */

#include <stdlib.h>
#include <string.h>

enum { ADAMUTANT_SPAWN_FAILED = -1000 };

#ifdef _WIN32

#include <windows.h>

int adamutant_run (const char *command, const char *directory,
                   const char *log_path, const char *extra_env,
                   int timeout_ms, int *timed_out, int *elapsed_ms)
{
  SECURITY_ATTRIBUTES sa = { sizeof (sa), NULL, TRUE };
  HANDLE log, nul, job;
  STARTUPINFOEXA si;
  PROCESS_INFORMATION pi;
  SIZE_T attr_size = 0;
  HANDLE inherit[2];
  char *cmdline, *env, *penv;
  size_t env_len, extra_len;
  DWORD wait, code = 0;
  ULONGLONG start;
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;

  *timed_out = 0;
  *elapsed_ms = 0;

  log = CreateFileA (log_path, GENERIC_WRITE, FILE_SHARE_READ, &sa,
                     CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (log == INVALID_HANDLE_VALUE)
    return ADAMUTANT_SPAWN_FAILED;
  nul = CreateFileA ("NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                     &sa, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);

  /* Environment block: the current environment plus EXTRA_ENV.  */
  penv = GetEnvironmentStringsA ();
  for (env_len = 0; penv[env_len] != '\0' || penv[env_len + 1] != '\0';
       env_len++)
    ;
  env_len += 1;
  extra_len = strlen (extra_env);
  env = malloc (env_len + extra_len + 2);
  memcpy (env, penv, env_len);
  memcpy (env + env_len, extra_env, extra_len + 1);
  env[env_len + extra_len + 1] = '\0';
  FreeEnvironmentStringsA (penv);

  cmdline = malloc (strlen (command) + 32);
  strcpy (cmdline, "cmd.exe /d /s /c \"");
  strcat (cmdline, command);
  strcat (cmdline, "\"");

  ZeroMemory (&si, sizeof (si));
  si.StartupInfo.cb = sizeof (si);
  si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  si.StartupInfo.hStdInput = nul;
  si.StartupInfo.hStdOutput = log;
  si.StartupInfo.hStdError = log;

  /* Only the log and NUL handles are inherited, even when several workers
     spawn processes concurrently.  */
  inherit[0] = log;
  inherit[1] = nul;
  InitializeProcThreadAttributeList (NULL, 1, 0, &attr_size);
  si.lpAttributeList = malloc (attr_size);
  InitializeProcThreadAttributeList (si.lpAttributeList, 1, 0, &attr_size);
  UpdateProcThreadAttribute (si.lpAttributeList, 0,
                             PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherit,
                             sizeof (inherit), NULL, NULL);

  job = CreateJobObjectA (NULL, NULL);
  ZeroMemory (&limits, sizeof (limits));
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  SetInformationJobObject (job, JobObjectExtendedLimitInformation, &limits,
                           sizeof (limits));

  start = GetTickCount64 ();
  if (!CreateProcessA (NULL, cmdline, NULL, NULL, TRUE,
                       CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT
                       | CREATE_NO_WINDOW,
                       env, directory, &si.StartupInfo, &pi))
    {
      DeleteProcThreadAttributeList (si.lpAttributeList);
      free (si.lpAttributeList);
      free (cmdline);
      free (env);
      CloseHandle (job);
      CloseHandle (log);
      CloseHandle (nul);
      return ADAMUTANT_SPAWN_FAILED;
    }
  AssignProcessToJobObject (job, pi.hProcess);
  ResumeThread (pi.hThread);
  CloseHandle (pi.hThread);

  wait = WaitForSingleObject (pi.hProcess,
                              timeout_ms > 0 ? (DWORD) timeout_ms : INFINITE);
  if (wait == WAIT_TIMEOUT)
    {
      *timed_out = 1;
      TerminateJobObject (job, 1);
      WaitForSingleObject (pi.hProcess, INFINITE);
    }
  GetExitCodeProcess (pi.hProcess, &code);
  *elapsed_ms = (int) (GetTickCount64 () - start);
  TerminateJobObject (job, 1);

  CloseHandle (pi.hProcess);
  CloseHandle (job);
  DeleteProcThreadAttributeList (si.lpAttributeList);
  free (si.lpAttributeList);
  free (cmdline);
  free (env);
  CloseHandle (log);
  CloseHandle (nul);
  return (int) code;
}

#else

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static long long now_ms (void)
{
  struct timespec ts;
  clock_gettime (CLOCK_MONOTONIC, &ts);
  return (long long) ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int adamutant_run (const char *command, const char *directory,
                   const char *log_path, const char *extra_env,
                   int timeout_ms, int *timed_out, int *elapsed_ms)
{
  int log, nul, status = 0, count = 0, i;
  char **envp;
  char *argv[4];
  pid_t pid, r;
  long long start;
  const struct timespec tick = { 0, 10 * 1000 * 1000 };

  *timed_out = 0;
  *elapsed_ms = 0;

  log = open (log_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  if (log < 0)
    return ADAMUTANT_SPAWN_FAILED;
  nul = open ("/dev/null", O_RDONLY | O_CLOEXEC);

  /* Everything the child needs is prepared before fork, so the child only
     calls async-signal-safe functions (the parent runs Ada tasks).  */
  while (environ[count] != NULL)
    count++;
  envp = malloc ((count + 2) * sizeof (char *));
  for (i = 0; i < count; i++)
    envp[i] = environ[i];
  envp[count] = (char *) extra_env;
  envp[count + 1] = NULL;
  argv[0] = "/bin/sh";
  argv[1] = "-c";
  argv[2] = (char *) command;
  argv[3] = NULL;

  start = now_ms ();
  pid = fork ();
  if (pid < 0)
    {
      free (envp);
      close (log);
      if (nul >= 0)
        close (nul);
      return ADAMUTANT_SPAWN_FAILED;
    }
  if (pid == 0)
    {
      setpgid (0, 0);
      if (chdir (directory) != 0)
        _exit (127);
      if (nul >= 0)
        dup2 (nul, 0);
      dup2 (log, 1);
      dup2 (log, 2);
      execve ("/bin/sh", argv, envp);
      _exit (127);
    }
  setpgid (pid, pid);
  free (envp);
  close (log);
  if (nul >= 0)
    close (nul);

  for (;;)
    {
      r = waitpid (pid, &status, WNOHANG);
      if (r == pid)
        break;
      if (r < 0 && errno != EINTR)
        {
          status = 0;
          break;
        }
      if (timeout_ms > 0 && now_ms () - start >= timeout_ms)
        {
          *timed_out = 1;
          kill (-pid, SIGKILL);
          while (waitpid (pid, &status, 0) < 0 && errno == EINTR)
            ;
          break;
        }
      nanosleep (&tick, NULL);
    }
  *elapsed_ms = (int) (now_ms () - start);
  kill (-pid, SIGKILL);

  if (WIFEXITED (status))
    return WEXITSTATUS (status);
  if (WIFSIGNALED (status))
    return 128 + WTERMSIG (status);
  return 255;
}

#endif
