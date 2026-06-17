// PHP-FPM hardened init — replaces entrypoint.sh + cgi-fcgi healthcheck.
// Static binary, zero shell dependency.
//
// Usage:
//
//	init --healthcheck      FastCGI PING/PONG check (exit 0/1)
//	init --setup-dirs       create runtime directories (build-time, FROM scratch)
//	init [CMD [ARGS...]]    entrypoint: env overrides, then exec CMD
package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const (
	phpUID  = 1999
	phpGID  = 1999
	fpmAddr = "127.0.0.1:9000"

	fpmConfPath = "/usr/local/etc/php-fpm.d/www.conf"
	phpConfDir  = "/usr/local/etc/php/conf.d"
)

// ---------------------------------------------------------------------------
// FastCGI constants (minimal client, no external dependency)
// ---------------------------------------------------------------------------

const (
	fcgiVersion       = 1
	fcgiBeginRequest  = 1
	fcgiEndRequest    = 3
	fcgiParams        = 4
	fcgiStdin         = 5
	fcgiStdout        = 6
	fcgiStderr        = 7
	fcgiRoleResponder = 1
)

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "--healthcheck":
			os.Exit(healthcheck())
		case "--setup-dirs":
			if err := setupDirs(); err != nil {
				fmt.Fprintf(os.Stderr, "[init][ERROR] setup-dirs: %v\n", err)
				os.Exit(1)
			}
			return
		}
	}
	if err := entrypoint(); err != nil {
		fmt.Fprintf(os.Stderr, "[init][ERROR] %v\n", err)
		os.Exit(1)
	}
}

// ---------------------------------------------------------------------------
// Setup directories — called at build time in FROM scratch stage.
// ---------------------------------------------------------------------------

func setupDirs() error {
	dirs := []struct {
		path string
		mode os.FileMode
		uid  int
		gid  int
	}{
		{"/var", 0755, 0, 0},
		{"/var/log", 0755, 0, 0},
		{"/var/run", 0755, 0, 0},
		{"/var/www", 0755, 0, 0},
		{"/var/www/html", 0755, phpUID, phpGID},
		{"/var/log/php-fpm", 0755, phpUID, phpGID},
		{"/var/run/php-fpm", 0755, phpUID, phpGID},
		{"/tmp", 01777, 0, 0},
	}
	for _, d := range dirs {
		fmt.Printf("[init] mkdir %s (mode=%04o uid=%d gid=%d)\n", d.path, d.mode, d.uid, d.gid)
		if err := os.MkdirAll(d.path, d.mode); err != nil {
			return fmt.Errorf("mkdir %s: %w", d.path, err)
		}
		if err := os.Chmod(d.path, d.mode); err != nil {
			return fmt.Errorf("chmod %s: %w", d.path, err)
		}
		if err := os.Chown(d.path, d.uid, d.gid); err != nil {
			return fmt.Errorf("chown %s: %w", d.path, err)
		}
	}

	// Log symlinks
	for _, link := range []struct{ src, dst string }{
		{"/dev/stderr", "/var/log/php-fpm/error.log"},
	} {
		os.Remove(link.dst)
		if err := os.Symlink(link.src, link.dst); err != nil {
			return fmt.Errorf("symlink %s -> %s: %w", link.dst, link.src, err)
		}
	}

	// PID file placeholder
	pidFile := "/var/run/php-fpm/php-fpm.pid"
	f, err := os.Create(pidFile)
	if err != nil {
		return fmt.Errorf("create %s: %w", pidFile, err)
	}
	f.Close()
	os.Chown(pidFile, phpUID, phpGID)

	fmt.Println("[init] setup-dirs complete")
	return nil
}

// ---------------------------------------------------------------------------
// Healthcheck: FastCGI PING/PONG (replaces cgi-fcgi binary)
// ---------------------------------------------------------------------------

func healthcheck() int {
	body, err := fcgiGet(fpmAddr, map[string]string{
		"SCRIPT_NAME":     "/ping",
		"SCRIPT_FILENAME": "/ping",
		"REQUEST_METHOD":  "GET",
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "[healthcheck] FastCGI error: %v\n", err)
		return 1
	}
	if !strings.Contains(body, "pong") {
		fmt.Fprintf(os.Stderr, "[healthcheck] expected 'pong', got: %s\n", body)
		return 1
	}
	return 0
}

// fcgiGet performs a minimal FastCGI request and returns the stdout body.
func fcgiGet(addr string, params map[string]string) (string, error) {
	conn, err := net.DialTimeout("tcp", addr, 3*time.Second)
	if err != nil {
		return "", fmt.Errorf("connect %s: %w", addr, err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))

	reqID := uint16(1)

	// BEGIN_REQUEST (role=RESPONDER, flags=0)
	beginBody := make([]byte, 8)
	binary.BigEndian.PutUint16(beginBody[0:2], fcgiRoleResponder)
	if err := fcgiWriteRecord(conn, fcgiBeginRequest, reqID, beginBody); err != nil {
		return "", err
	}

	// PARAMS
	paramsPayload := fcgiEncodeParams(params)
	if err := fcgiWriteRecord(conn, fcgiParams, reqID, paramsPayload); err != nil {
		return "", err
	}
	// Empty PARAMS (end of params)
	if err := fcgiWriteRecord(conn, fcgiParams, reqID, nil); err != nil {
		return "", err
	}

	// Empty STDIN (end of input)
	if err := fcgiWriteRecord(conn, fcgiStdin, reqID, nil); err != nil {
		return "", err
	}

	// Read response
	var stdout []byte
	for {
		recType, _, content, err := fcgiReadRecord(conn)
		if err != nil {
			if err == io.EOF {
				break
			}
			return "", err
		}
		switch recType {
		case fcgiStdout:
			stdout = append(stdout, content...)
		case fcgiStderr:
			// ignore stderr
		case fcgiEndRequest:
			return extractBody(stdout), nil
		}
	}
	return extractBody(stdout), nil
}

func fcgiWriteRecord(w io.Writer, recType byte, reqID uint16, content []byte) error {
	contentLen := len(content)
	padding := (8 - contentLen%8) % 8

	header := make([]byte, 8)
	header[0] = fcgiVersion
	header[1] = recType
	binary.BigEndian.PutUint16(header[2:4], reqID)
	binary.BigEndian.PutUint16(header[4:6], uint16(contentLen))
	header[6] = byte(padding)
	header[7] = 0

	if _, err := w.Write(header); err != nil {
		return err
	}
	if contentLen > 0 {
		if _, err := w.Write(content); err != nil {
			return err
		}
	}
	if padding > 0 {
		pad := make([]byte, padding)
		if _, err := w.Write(pad); err != nil {
			return err
		}
	}
	return nil
}

func fcgiReadRecord(r io.Reader) (recType byte, reqID uint16, content []byte, err error) {
	header := make([]byte, 8)
	if _, err = io.ReadFull(r, header); err != nil {
		return
	}
	recType = header[1]
	reqID = binary.BigEndian.Uint16(header[2:4])
	contentLen := binary.BigEndian.Uint16(header[4:6])
	paddingLen := header[6]

	if contentLen > 0 {
		content = make([]byte, contentLen)
		if _, err = io.ReadFull(r, content); err != nil {
			return
		}
	}
	if paddingLen > 0 {
		pad := make([]byte, paddingLen)
		if _, err = io.ReadFull(r, pad); err != nil {
			return
		}
	}
	return
}

func fcgiEncodeParams(params map[string]string) []byte {
	var buf []byte
	for k, v := range params {
		buf = append(buf, fcgiEncodeLength(len(k))...)
		buf = append(buf, fcgiEncodeLength(len(v))...)
		buf = append(buf, []byte(k)...)
		buf = append(buf, []byte(v)...)
	}
	return buf
}

func fcgiEncodeLength(n int) []byte {
	if n < 128 {
		return []byte{byte(n)}
	}
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, uint32(n)|0x80000000)
	return b
}

// extractBody strips HTTP headers from FastCGI stdout (Content-Type, etc.)
func extractBody(data []byte) string {
	s := string(data)
	if idx := strings.Index(s, "\r\n\r\n"); idx >= 0 {
		return s[idx+4:]
	}
	if idx := strings.Index(s, "\n\n"); idx >= 0 {
		return s[idx+2:]
	}
	return s
}

// ---------------------------------------------------------------------------
// Entrypoint: env overrides + exec php-fpm (replaces entrypoint.sh)
// ---------------------------------------------------------------------------

func entrypoint() error {
	// Ensure writable dirs
	for _, dir := range []string{"/var/www/html", "/var/log/php-fpm", "/var/run/php-fpm", "/tmp"} {
		if err := ensureWritable(dir, phpUID, phpGID); err != nil {
			log("WARNING: %v", err)
		}
	}

	// WP_DEBUG mode (opt-in via WP_DEBUG=1)
	if os.Getenv("WP_DEBUG") == "1" {
		content := "display_errors = On\n" +
			"display_startup_errors = On\n" +
			"error_reporting = E_ALL\n" +
			"opcache.revalidate_freq = 0\n" +
			"opcache.validate_timestamps = 1\n" +
			"opcache.jit = off\n"
		if err := writeFile(filepath.Join(phpConfDir, "zz-debug.ini"), content, 0644); err != nil {
			log("WARNING: cannot enable WP_DEBUG (read-only fs?): %v", err)
		} else {
			log("WP_DEBUG mode enabled")
		}
	}

	// PHP_PM_MAX_CHILDREN override → modify www.conf in-place
	if v := os.Getenv("PHP_PM_MAX_CHILDREN"); v != "" {
		if err := replaceInFile(fpmConfPath, "pm.max_children", "pm.max_children = "+v); err != nil {
			log("WARNING: failed to set pm.max_children: %v", err)
		}
	}

	// PHP_MEMORY_LIMIT override
	if v := os.Getenv("PHP_MEMORY_LIMIT"); v != "" {
		content := "memory_limit = " + v + "\n"
		if err := writeFile(filepath.Join(phpConfDir, "zz-memory.ini"), content, 0644); err != nil {
			log("WARNING: cannot set memory_limit (read-only fs?): %v", err)
		}
	}

	// PHP_UPLOAD_MAX_FILESIZE override
	if v := os.Getenv("PHP_UPLOAD_MAX_FILESIZE"); v != "" {
		content := "upload_max_filesize = " + v + "\npost_max_size = " + v + "\n"
		if err := writeFile(filepath.Join(phpConfDir, "zz-upload.ini"), content, 0644); err != nil {
			log("WARNING: cannot set upload_max_filesize (read-only fs?): %v", err)
		}
	}

	log("PHP-FPM ready")

	// Exec php-fpm (replaces this process)
	return execCmd(os.Args[1:])
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func execCmd(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("no command specified")
	}
	bin, err := exec.LookPath(args[0])
	if err != nil {
		return fmt.Errorf("command not found: %s", args[0])
	}
	return syscall.Exec(bin, args, os.Environ())
}

func ensureWritable(path string, uid, gid int) error {
	if !exists(path) {
		return nil
	}
	tmp, err := os.CreateTemp(path, ".write-test-*")
	if err == nil {
		name := tmp.Name()
		tmp.Close()
		os.Remove(name)
		return nil
	}
	if chErr := chownRecursive(path, uid, gid); chErr == nil {
		tmp2, err2 := os.CreateTemp(path, ".write-test-*")
		if err2 == nil {
			name := tmp2.Name()
			tmp2.Close()
			os.Remove(name)
			return nil
		}
	}
	return fmt.Errorf("%s is not writable by uid %d", path, os.Getuid())
}

func chownRecursive(path string, uid, gid int) error {
	return filepath.Walk(path, func(name string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		return os.Chown(name, uid, gid)
	})
}

func writeFile(path, content string, mode os.FileMode) error {
	return os.WriteFile(path, []byte(content), mode)
}

// replaceInFile replaces a line starting with prefix in the given file.
func replaceInFile(path, prefix, replacement string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	lines := strings.Split(string(data), "\n")
	found := false
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, prefix) {
			lines[i] = replacement
			found = true
			break
		}
	}
	if !found {
		return fmt.Errorf("line starting with %q not found in %s", prefix, path)
	}
	return os.WriteFile(path, []byte(strings.Join(lines, "\n")), 0644)
}

func log(format string, a ...any) {
	fmt.Printf("[init] "+format+"\n", a...)
}
