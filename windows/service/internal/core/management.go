package core

import (
	"bytes"
	"regexp"
	"strconv"
	"strings"
)

// ManagementState is one `>STATE:` notification
// (`time,state,description,tun_ip,remote_ip,…`).
type ManagementState struct {
	// Unix time of the transition; 0 when absent.
	Time int64
	// `CONNECTED`, `RECONNECTING`, `EXITING`, `WAIT`, `AUTH`, …
	Name string
	// `SUCCESS`, the reconnect reason, the exit reason, …
	Description string
	TunnelIP    string
	RemoteIP    string
}

// ManagementEventKind identifies a parsed management-interface line.
type ManagementEventKind string

const (
	// EventState is a `>STATE:` notification.
	EventState ManagementEventKind = "state"
	// EventLog is a `>LOG:time,flags,message` line.
	EventLog ManagementEventKind = "log"
	// EventPasswordNeeded is `>PASSWORD:Need '<kind>' …` (`Auth` or `Private Key`).
	EventPasswordNeeded ManagementEventKind = "passwordNeeded"
	// EventPasswordVerificationFailed is `>PASSWORD:Verification Failed: '<kind>'`.
	EventPasswordVerificationFailed ManagementEventKind = "passwordVerificationFailed"
	// EventFatal is a `>FATAL:` notification.
	EventFatal ManagementEventKind = "fatal"
	// EventHold is a `>HOLD:` notification.
	EventHold ManagementEventKind = "hold"
	// EventInfo is a `>INFO:` notification.
	EventInfo ManagementEventKind = "info"
	// EventBytecount is `>BYTECOUNT:in,out`.
	EventBytecount ManagementEventKind = "bytecount"
	// EventSuccess is a `SUCCESS: …` reply to a command.
	EventSuccess ManagementEventKind = "success"
	// EventError is an `ERROR: …` reply to a command.
	EventError ManagementEventKind = "error"
	// EventEcho is a `>LOG:` line that only echoes something the management channel already
	// carried: with `log on` OpenVPN repeats every `>STATE:` as `MANAGEMENT: >STATE:…`
	// (spike S3b) and every command it receives as `MANAGEMENT: CMD '…'` (the latter
	// includes `username` arguments verbatim). Consumers drop it.
	EventEcho ManagementEventKind = "echo"
	// EventOther is anything else (`END`, `>ECHO`, `>NOTIFY`, …).
	EventOther ManagementEventKind = "other"
)

// ManagementEvent is a line received from the OpenVPN management interface, parsed
// (docs/design/04-tunnels.md, "Management protocol handling").
type ManagementEvent struct {
	Kind ManagementEventKind
	// EventState.
	State ManagementState
	// EventLog: the flags (`I`, `W`, `F`, …).
	Flags string
	// EventLog, EventFatal, EventHold, EventInfo, EventSuccess, EventError: the payload.
	Message string
	// EventPasswordNeeded, EventPasswordVerificationFailed: `Auth` or `Private Key`.
	PasswordKind string
	// EventBytecount.
	In, Out int64
	// EventEcho, EventOther: the whole line.
	Line string
}

const (
	stateEchoPrefix   = "MANAGEMENT: >STATE:"
	commandEchoPrefix = "MANAGEMENT: CMD '"
)

// ParseManagementLine classifies one line of the management channel.
func ParseManagementLine(line string) ManagementEvent {
	if strings.HasPrefix(line, ">") {
		colon := strings.IndexByte(line, ':')
		if colon < 0 {
			return ManagementEvent{Kind: EventOther, Line: line}
		}
		kind, payload := line[1:colon], line[colon+1:]
		switch kind {
		case "STATE":
			return ManagementEvent{Kind: EventState, State: parseManagementState(payload)}
		case "LOG":
			return parseManagementLog(payload)
		case "PASSWORD":
			return parseManagementPassword(payload)
		case "FATAL":
			return ManagementEvent{Kind: EventFatal, Message: payload}
		case "HOLD":
			return ManagementEvent{Kind: EventHold, Message: payload}
		case "INFO":
			return ManagementEvent{Kind: EventInfo, Message: payload}
		case "BYTECOUNT":
			parts := strings.Split(payload, ",")
			if len(parts) != 2 {
				return ManagementEvent{Kind: EventOther, Line: line}
			}
			in, errIn := strconv.ParseInt(parts[0], 10, 64)
			out, errOut := strconv.ParseInt(parts[1], 10, 64)
			if errIn != nil || errOut != nil {
				return ManagementEvent{Kind: EventOther, Line: line}
			}
			return ManagementEvent{Kind: EventBytecount, In: in, Out: out}
		default:
			return ManagementEvent{Kind: EventOther, Line: line}
		}
	}
	if rest, ok := strings.CutPrefix(line, "SUCCESS:"); ok {
		return ManagementEvent{Kind: EventSuccess, Message: strings.TrimSpace(rest)}
	}
	if rest, ok := strings.CutPrefix(line, "ERROR:"); ok {
		return ManagementEvent{Kind: EventError, Message: strings.TrimSpace(rest)}
	}
	return ManagementEvent{Kind: EventOther, Line: line}
}

func parseManagementState(payload string) ManagementState {
	parts := strings.Split(payload, ",")
	field := func(index int) string {
		if index < len(parts) {
			return parts[index]
		}
		return ""
	}
	state := ManagementState{
		Name: field(1), Description: field(2), TunnelIP: field(3), RemoteIP: field(4),
	}
	if seconds, err := strconv.ParseInt(field(0), 10, 64); err == nil {
		state.Time = seconds
	}
	return state
}

func parseManagementLog(payload string) ManagementEvent {
	parts := strings.SplitN(payload, ",", 3)
	if len(parts) != 3 {
		return ManagementEvent{Kind: EventLog, Message: payload}
	}
	message := parts[2]
	if strings.HasPrefix(message, stateEchoPrefix) || strings.HasPrefix(message, commandEchoPrefix) {
		return ManagementEvent{Kind: EventEcho, Line: ">LOG:" + payload}
	}
	return ManagementEvent{Kind: EventLog, Flags: parts[1], Message: message}
}

func parseManagementPassword(payload string) ManagementEvent {
	if strings.HasPrefix(payload, "Need '") {
		if kind, ok := firstQuoted(payload); ok {
			return ManagementEvent{Kind: EventPasswordNeeded, PasswordKind: kind}
		}
	}
	if strings.HasPrefix(payload, "Verification Failed:") {
		if kind, ok := firstQuoted(payload); ok {
			return ManagementEvent{Kind: EventPasswordVerificationFailed, PasswordKind: kind}
		}
	}
	return ManagementEvent{Kind: EventOther, Line: ">PASSWORD:" + payload}
}

// firstQuoted returns the first `'…'` substring.
func firstQuoted(text string) (string, bool) {
	open := strings.IndexByte(text, '\'')
	if open < 0 {
		return "", false
	}
	rest := text[open+1:]
	close := strings.IndexByte(rest, '\'')
	if close < 0 {
		return "", false
	}
	return rest[:close], true
}

// LevelForLogFlags maps `>LOG` flags to a level (docs/design/06-logging.md): `F` error,
// `W`/`N` warning, `D` debug, everything else info.
func LevelForLogFlags(flags string) LogLevel {
	switch {
	case strings.Contains(flags, "F"):
		return LogLevelError
	case strings.Contains(flags, "W"), strings.Contains(flags, "N"):
		return LogLevelWarning
	case strings.Contains(flags, "D"):
		return LogLevelDebug
	default:
		return LogLevelInfo
	}
}

// pushReplyOptions returns the comma-separated options of a logged PUSH_REPLY.
func pushReplyOptions(message string) ([]string, bool) {
	_, body, ok := strings.Cut(message, "PUSH_REPLY,")
	if !ok {
		return nil, false
	}
	if quote := strings.LastIndexByte(body, '\''); quote >= 0 {
		body = body[:quote]
	}
	return strings.Split(body, ","), true
}

// PushedDNS returns the `dhcp-option DNS <ip>` entries of a logged `PUSH_REPLY`, in order,
// de-duplicated; false when the line is not a PUSH_REPLY.
func PushedDNS(message string) ([]string, bool) {
	options, ok := pushReplyOptions(message)
	if !ok {
		return nil, false
	}
	servers := []string{}
	for _, option := range options {
		words := strings.Fields(option)
		if len(words) != 3 || words[0] != "dhcp-option" || words[1] != "DNS" {
			continue
		}
		if !containsString(servers, words[2]) {
			servers = append(servers, words[2])
		}
	}
	return servers, true
}

// PushedRouteGateway returns the `route-gateway <ip>` of a logged `PUSH_REPLY` — the next
// hop of the adapter's scoped default route (docs/design/08-windows.md, "Routes"); it is
// pushed even under `--route-nopull` (spike S4b). Without `route-gateway`, the peer address
// of a net30 `ifconfig <local> <remote>` serves (a subnet netmask does not). False when
// the line is not a PUSH_REPLY or carries neither.
func PushedRouteGateway(message string) (string, bool) {
	options, ok := pushReplyOptions(message)
	if !ok {
		return "", false
	}
	fallback := ""
	for _, option := range options {
		words := strings.Fields(option)
		switch {
		case len(words) == 2 && words[0] == "route-gateway":
			return words[1], true
		case len(words) == 3 && words[0] == "ifconfig" && fallback == "" && !looksLikeNetmask(words[2]):
			fallback = words[2]
		}
	}
	return fallback, fallback != ""
}

func looksLikeNetmask(address string) bool {
	return strings.HasPrefix(address, "255.")
}

func containsString(list []string, value string) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}
	return false
}

// ManagementPasswordPrompt is what OpenVPN sends first on a password-protected management
// channel (`--management 127.0.0.1 <port> <password-file>`, the Windows form) — without a
// trailing newline, so it never arrives as a line.
const ManagementPasswordPrompt = "ENTER PASSWORD:"

// ManagementPasswordAccepted is the `SUCCESS:` payload after the right password.
const ManagementPasswordAccepted = "password is correct"

// IsManagementPasswordPrompt reports whether an unterminated read buffer ends with the
// password prompt; the socket client answers it before anything else.
func IsManagementPasswordPrompt(buffered []byte) bool {
	return bytes.HasSuffix(bytes.TrimRight(buffered, " "), []byte(ManagementPasswordPrompt))
}

// Commands written to the management socket. Values are quoted per the management
// interface spec (backslash-escaped `"` and `\`); the caller must never log them.
const (
	ManagementStateOn     = "state on"
	ManagementLogOn       = "log on"
	ManagementBytecount   = "bytecount 5"
	ManagementHoldRelease = "hold release"
	ManagementSignalTerm  = "signal SIGTERM"
)

// ManagementUsername is the reply to `>PASSWORD:Need '<kind>' username/password`.
func ManagementUsername(kind, value string) string {
	return "username " + ManagementQuote(kind) + " " + ManagementQuote(value)
}

// ManagementPassword is the reply to a `>PASSWORD:Need '<kind>'` prompt.
func ManagementPassword(kind, value string) string {
	return "password " + ManagementQuote(kind) + " " + ManagementQuote(value)
}

// ManagementQuote wraps a value in double quotes, escaping `"` and `\`.
func ManagementQuote(value string) string {
	var out strings.Builder
	out.Grow(len(value) + 2)
	out.WriteByte('"')
	for _, r := range value {
		if r == '"' || r == '\\' {
			out.WriteByte('\\')
		}
		out.WriteRune(r)
	}
	out.WriteByte('"')
	return out.String()
}

var openedAdapterPattern = regexp.MustCompile(`(?:^|\s)\S+ device \[(.+)\] opened$`)

// OpenedAdapter extracts the adapter name from OpenVPN's open line: `init.c` logs
// `"%s device [%s] opened"` with the backend driver (`ovpn-dco`, `tap-windows6`) and the
// adapter name — the Windows replacement for the Darwin `Opened utun device utunN`
// (spike S3c). A soft restart logs `Preserving previous TUN/TAP instance: …` instead.
func OpenedAdapter(message string) (string, bool) {
	match := openedAdapterPattern.FindStringSubmatch(message)
	if match == nil {
		return "", false
	}
	return match[1], true
}

// OpenVPN's message flags (error.h) as printed in hex by `--machine-readable-output`.
const (
	openVPNFlagFatal    = 1 << 4
	openVPNFlagNonFatal = 1 << 5
	openVPNFlagWarn     = 1 << 6
	openVPNFlagDebug    = 1 << 7
)

// ParseOutputLine splits a line of openvpn's own stdout under `--machine-readable-output`:
// `<epoch>.<micros> <flags-hex> <message>` (error.c; the timestamp is printed even with
// `--suppress-timestamps`). The hex bitmask is converted to the `>LOG` letters (`F`, `N`,
// `W`, `D`, else `I`) so LevelForLogFlags works on both channels; the letter form is
// accepted too. A line in another shape yields ("", line).
func ParseOutputLine(line string) (flags, message string) {
	parts := strings.SplitN(line, " ", 3)
	if len(parts) != 3 || !isEpoch(parts[0]) || parts[1] == "" {
		return "", line
	}
	if isUpperLetters(parts[1]) {
		return parts[1], parts[2]
	}
	mask, err := strconv.ParseUint(parts[1], 16, 32)
	if err != nil {
		return "", line
	}
	return flagsFromMask(mask), parts[2]
}

func flagsFromMask(mask uint64) string {
	var out strings.Builder
	if mask&openVPNFlagFatal != 0 {
		out.WriteByte('F')
	}
	if mask&openVPNFlagNonFatal != 0 {
		out.WriteByte('N')
	}
	if mask&openVPNFlagWarn != 0 {
		out.WriteByte('W')
	}
	if mask&openVPNFlagDebug != 0 {
		out.WriteByte('D')
	}
	if out.Len() == 0 {
		return "I"
	}
	return out.String()
}

func isEpoch(text string) bool {
	seconds, fraction, hasFraction := strings.Cut(text, ".")
	if !isDigits(seconds) {
		return false
	}
	return !hasFraction || isDigits(fraction)
}

func isDigits(text string) bool {
	if text == "" {
		return false
	}
	for _, r := range text {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func isUpperLetters(text string) bool {
	for _, r := range text {
		if r < 'A' || r > 'Z' {
			return false
		}
	}
	return text != ""
}
