// apkg — пакетный менеджер для Яндекс.Станции (Alice Panel).
package main

import (
	"bytes"
	"context"
	"crypto/md5"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

const (
	defaultIndexURL = "https://raw.githubusercontent.com/initialfox/yandex-station-repo/main/packages.json"
	// пакеты лежат на ветке pkg (raw), не в Releases
	defaultBaseURL = "https://raw.githubusercontent.com/initialfox/yandex-station-repo/pkg"
	version        = "1.0.8"
)

// только GitHub raw
var indexFallbacks = []string{
	"https://raw.githubusercontent.com/initialfox/yandex-station-repo/main/packages.json",
	"https://raw.githubusercontent.com/initialfox/yandex-station-repo/pkg/packages.json",
	"https://github.com/initialfox/yandex-station-repo/raw/refs/heads/main/packages.json",
}

// paths — Android (/data/local) vs buildroot (/opt, /usr/local, /tmp).
type paths struct {
	Bindir string
	Opt    string
	Cache  string
	State  string
	Flavor string // "android" | "buildroot"
}

var P paths

func init() {
	P = detectPaths()
	// Android: иначе Go tzdata орёт ANDROID_DATA/ROOT not set
	if P.Flavor == "android" {
		if os.Getenv("ANDROID_DATA") == "" {
			_ = os.Setenv("ANDROID_DATA", "/data")
		}
		if os.Getenv("ANDROID_ROOT") == "" {
			_ = os.Setenv("ANDROID_ROOT", "/system")
		}
	}
}

func detectPaths() paths {
	p := paths{
		Bindir: os.Getenv("APKG_BINDIR"),
		Opt:    os.Getenv("APKG_OPT"),
		Cache:  os.Getenv("APKG_CACHE"),
		State:  os.Getenv("APKG_STATE"),
	}

	// Android = bionic linker. Не угадываем по /data/local (на buildroot тоже бывает).
	isAndroid := fileExists("/system/bin/linker64") || fileExists("/system/bin/linker")

	if isAndroid {
		p.Flavor = "android"
		if p.Bindir == "" {
			p.Bindir = "/data/local/bin"
		}
		if p.Opt == "" {
			p.Opt = "/data/local/opt"
		}
		if p.State == "" {
			p.State = "/data/local/apkg"
		}
		if p.Cache == "" {
			// /sdcard часто пустой/без mount — сначала /data/local
			p.Cache = firstWritableDir(
				"/data/local/tmp/apkg-cache",
				"/data/local/apkg/cache",
				"/sdcard/apkg-cache",
				"/tmp/apkg-cache",
			)
		}
	} else {
		// buildroot — без /sdcard и /system/bin/sh
		p.Flavor = "buildroot"
		if p.Bindir == "" {
			p.Bindir = firstWritableDir("/usr/local/bin", "/opt/bin", "/usr/bin", "/bin")
		}
		if p.Opt == "" {
			p.Opt = firstWritableDir(
				"/bkupgrade/data/local/opt",
				"/opt/alice",
				"/opt",
				"/usr/local/opt",
				"/data/local/opt",
			)
		}
		if p.State == "" {
			p.State = firstWritableDir(
				"/var/lib/apkg",
				"/bkupgrade/data/local/apkg",
				"/opt/apkg",
				"/tmp/apkg-state",
			)
		}
		if p.Cache == "" {
			// никогда не /sdcard
			p.Cache = firstWritableDir(
				"/var/cache/apkg",
				"/tmp/apkg-cache",
				"/bkupgrade/data/local/tmp/apkg-cache",
				filepath.Join(p.State, "cache"),
			)
		}
	}
	return p
}

func dirExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

func dirWritable(p string) bool {
	if !dirExists(p) {
		if err := os.MkdirAll(p, 0755); err != nil {
			return false
		}
	}
	f := filepath.Join(p, ".apkg-write-test")
	if err := os.WriteFile(f, []byte("1"), 0644); err != nil {
		return false
	}
	_ = os.Remove(f)
	return true
}

func firstWritableDir(cands ...string) string {
	for _, c := range cands {
		if c == "" {
			continue
		}
		if dirWritable(c) {
			return c
		}
	}
	// last resort
	_ = os.MkdirAll("/tmp/apkg", 0755)
	return "/tmp/apkg"
}

type pkgMeta struct {
	Name        string `json:"name"`
	Version     string `json:"version"`
	Arch        string `json:"arch"`
	Description string `json:"description"`
	Category    string `json:"category"`
	Kind        string `json:"kind"` // file | dir
	Asset       string `json:"asset"`
	URL         string `json:"url"` // legacy relative path inside asset tar
	Dest        string `json:"dest"`
	Check       string `json:"check"`
	Bin         string `json:"bin"`
	MD5         string `json:"md5"`
	Size        int64  `json:"size"`
	// Runtime: "static" — один файл; "musl" — бандл lib/ + *-run (не запускать голый ELF)
	Runtime string `json:"runtime"`
}

type repoMeta struct {
	Name        string    `json:"name"`
	Arch        string    `json:"arch"`
	Description string    `json:"description"`
	BaseURL     string    `json:"base_url"`
	IndexURL    string    `json:"index_url"`
	Packages    []pkgMeta `json:"packages"`
}

// публичные DNS: на станциях resolv.conf часто указывает на ::1:53 → connection refused
var publicDNS = []string{
	"77.88.8.8:53", // Yandex
	"8.8.8.8:53",
	"1.1.1.1:53",
	"9.9.9.9:53",
}

var dnsResolver = &net.Resolver{
	PreferGo: true,
	Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
		d := net.Dialer{Timeout: 3 * time.Second}
		var last error
		for _, dns := range publicDNS {
			c, err := d.DialContext(ctx, "udp", dns)
			if err == nil {
				return c, nil
			}
			last = err
			c, err = d.DialContext(ctx, "tcp", dns)
			if err == nil {
				return c, nil
			}
			last = err
		}
		return nil, last
	},
}

var httpClient = &http.Client{
	Timeout: 120 * time.Second,
	Transport: &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, // станция без CA
		// HTTP/2 на Android/bionic иногда ломается
		ForceAttemptHTTP2: false,
		TLSNextProto:      map[string]func(authority string, c *tls.Conn) http.RoundTripper{},
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}
			if ip := net.ParseIP(host); ip != nil {
				d := net.Dialer{Timeout: 15 * time.Second}
				return d.DialContext(ctx, network, addr)
			}
			ips, err := lookupPreferV4(ctx, host)
			if err != nil || len(ips) == 0 {
				d := net.Dialer{Timeout: 15 * time.Second}
				return d.DialContext(ctx, network, addr)
			}
			d := net.Dialer{Timeout: 15 * time.Second}
			var last error
			for _, ip := range ips {
				c, err := d.DialContext(ctx, network, net.JoinHostPort(ip, port))
				if err == nil {
					return c, nil
				}
				last = err
			}
			return nil, last
		},
	},
}

func lookupPreferV4(ctx context.Context, host string) ([]string, error) {
	addrs, err := dnsResolver.LookupIPAddr(ctx, host)
	if err != nil {
		return nil, err
	}
	var v4, v6 []string
	for _, a := range addrs {
		s := a.IP.String()
		if a.IP.To4() != nil {
			v4 = append(v4, s)
		} else {
			v6 = append(v6, s)
		}
	}
	out := append(v4, v6...)
	if len(out) == 0 {
		return nil, fmt.Errorf("нет A/AAAA для %s", host)
	}
	return out, nil
}

// хосты GitHub (raw / редиректы)
var githubHosts = []string{
	"github.com",
	"raw.githubusercontent.com",
	"media.githubusercontent.com",
	"objects.githubusercontent.com",
	"release-assets.githubusercontent.com",
	"codeload.github.com",
	"api.github.com",
}

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		printHelp()
		os.Exit(0)
	}
	cmd := args[0]
	rest := args[1:]
	switch cmd {
	case "help", "-h", "--help":
		printHelp()
	case "version", "-V", "--version":
		fmt.Printf("apkg %s\n", version)
	case "update", "refresh":
		must(cmdUpdate())
	case "list", "ls":
		must(cmdList(rest))
	case "search":
		must(cmdSearch(rest))
	case "info", "show":
		must(cmdInfo(rest))
	case "install", "i", "add":
		must(cmdInstall(rest))
	case "remove", "rm", "uninstall":
		must(cmdRemove(rest))
	case "upgrade":
		must(cmdUpgrade(rest))
	case "paths":
		fmt.Printf("flavor %s\nbindir %s\nopt    %s\nstate  %s\ncache  %s\n", P.Flavor, P.Bindir, P.Opt, P.State, P.Cache)
	default:
		fmt.Fprintf(os.Stderr, "неизвестная команда: %s\n", cmd)
		printHelp()
		os.Exit(1)
	}
}

func printHelp() {
	fmt.Printf(`apkg — пакетный менеджер Яндекс.Станции (один бинарь)

  apkg update              обновить индекс
  apkg list [-i]           все пакеты (+ статус)
  apkg search <слово>      поиск
  apkg info <имя>          подробно
  apkg install <имя…>      поставить
  apkg remove <имя…>       удалить
  apkg upgrade [имя…]      обновить
  apkg paths               куда ставит на этой колонке

Сейчас: flavor=%s
  bindir %s
  opt    %s
  state  %s
  cache  %s

Musl-пакеты: целиком в opt/<имя> + symlink в bindir.
Обёртки: #!/bin/sh, в PATH — с абсолютным DIR (Android и buildroot).
Не запускай голый ELF из bin/ — будет «not found».

После установки apkg запускает «<команда> --version»: если программа не стартует
(ошибка загрузчика/интерпретатора), установка откатывается. Отключить: APKG_NOCHECK=1.

Переменные: APKG_INDEX APKG_BASE APKG_BINDIR APKG_OPT APKG_CACHE APKG_STATE APKG_NOCHECK
`, P.Flavor, P.Bindir, P.Opt, P.State, P.Cache)
}

func must(err error) {
	if err != nil {
		fmt.Fprintf(os.Stderr, "ошибка: %v\n", err)
		os.Exit(1)
	}
}

func indexURL() string {
	if v := os.Getenv("APKG_INDEX"); v != "" {
		return v
	}
	return defaultIndexURL
}

func baseURL(repo *repoMeta) string {
	if v := os.Getenv("APKG_BASE"); v != "" {
		return strings.TrimRight(v, "/")
	}
	if repo != nil && repo.BaseURL != "" {
		return strings.TrimRight(repo.BaseURL, "/")
	}
	return defaultBaseURL
}

func bindir() string {
	_ = os.MkdirAll(P.Bindir, 0755)
	return P.Bindir
}

func optDir() string {
	_ = os.MkdirAll(P.Opt, 0755)
	return P.Opt
}

func stateDir() string {
	_ = os.MkdirAll(P.State, 0755)
	return P.State
}

func cacheDir() string {
	_ = os.MkdirAll(P.Cache, 0755)
	return P.Cache
}

func cmdUpdate() error {
	repo, err := fetchIndex(true)
	if err != nil {
		return err
	}
	fmt.Printf("✓ индекс обновлён · %d пакетов · %s\n", len(repo.Packages), indexURL())
	return nil
}

func cmdList(args []string) error {
	repo, err := loadIndex()
	if err != nil {
		return err
	}
	onlyInstalled := false
	for _, a := range args {
		if a == "-i" || a == "--installed" {
			onlyInstalled = true
		}
	}
	fmt.Printf("\n  %-14s %-10s %-8s  %s\n", "ПАКЕТ", "ВЕРСИЯ", "СТАТУС", "ОПИСАНИЕ")
	fmt.Printf("  %s\n", strings.Repeat("─", 72))
	pkgs := append([]pkgMeta{}, repo.Packages...)
	sort.Slice(pkgs, func(i, j int) bool { return pkgs[i].Name < pkgs[j].Name })
	for _, p := range pkgs {
		on := isInstalled(p)
		if onlyInstalled && !on {
			continue
		}
		st := "—"
		if on {
			st = "есть"
		}
		desc := p.Description
		if len(desc) > 42 {
			desc = desc[:40] + "…"
		}
		fmt.Printf("  %-14s %-10s %-8s  %s\n", p.Name, p.Version, st, desc)
	}
	fmt.Println()
	return nil
}

func cmdSearch(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("укажи слово: apkg search vpn")
	}
	q := strings.ToLower(strings.Join(args, " "))
	repo, err := loadIndex()
	if err != nil {
		return err
	}
	n := 0
	for _, p := range repo.Packages {
		hay := strings.ToLower(p.Name + " " + p.Description + " " + p.Category)
		if strings.Contains(hay, q) {
			mark := " "
			if isInstalled(p) {
				mark = "✓"
			}
			fmt.Printf("  %s %-14s  %s\n", mark, p.Name, p.Description)
			n++
		}
	}
	if n == 0 {
		fmt.Println("ничего не найдено")
	}
	return nil
}

func cmdInfo(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("укажи имя: apkg info curl")
	}
	repo, err := loadIndex()
	if err != nil {
		return err
	}
	p := findPkg(repo, args[0])
	if p == nil {
		return fmt.Errorf("пакет %q не найден", args[0])
	}
	fmt.Printf("\n  %s  v%s\n", p.Name, p.Version)
	fmt.Printf("  %s\n\n", p.Description)
	fmt.Printf("  arch     %s\n", or(p.Arch, "aarch64"))
	fmt.Printf("  kind     %s\n", or(p.Kind, "file"))
	fmt.Printf("  size     %.1f МБ\n", float64(p.Size)/1024/1024)
	fmt.Printf("  asset    %s\n", assetName(*p))
	fmt.Printf("  dest     %s\n", installDest(*p))
	fmt.Printf("  check    %s\n", checkPath(*p))
	fmt.Printf("  status   %s\n\n", map[bool]string{true: "установлен", false: "не установлен"}[isInstalled(*p)])
	return nil
}

func cmdInstall(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("укажи пакет: apkg install curl")
	}
	repo, err := loadIndex()
	if err != nil {
		return err
	}
	for _, name := range args {
		p := findPkg(repo, name)
		if p == nil {
			return fmt.Errorf("пакет %q не найден", name)
		}
		if err := installOne(repo, *p); err != nil {
			return err
		}
	}
	return nil
}

func cmdRemove(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("укажи пакет: apkg remove nano")
	}
	repo, err := loadIndex()
	if err != nil {
		return err
	}
	for _, name := range args {
		p := findPkg(repo, name)
		if p == nil {
			return fmt.Errorf("пакет %q не найден", name)
		}
		if err := removeOne(*p); err != nil {
			return err
		}
		fmt.Printf("✓ удалён %s\n", name)
	}
	return nil
}

func cmdUpgrade(args []string) error {
	repo, err := fetchIndex(true)
	if err != nil {
		return err
	}
	targets := args
	if len(targets) == 0 {
		for _, p := range repo.Packages {
			if isInstalled(p) {
				targets = append(targets, p.Name)
			}
		}
	}
	if len(targets) == 0 {
		fmt.Println("нечего обновлять")
		return nil
	}
	var failed []string
	for _, name := range targets {
		p := findPkg(repo, name)
		if p == nil {
			continue
		}
		fmt.Printf("→ обновляю %s…\n", name)
		// один сломанный пакет не останавливает обновление остальных
		if err := installOne(repo, *p); err != nil {
			fmt.Fprintf(os.Stderr, "✗ %s: %v\n", name, err)
			failed = append(failed, name)
		}
	}
	if len(failed) > 0 {
		return fmt.Errorf("не обновлены: %s", strings.Join(failed, ", "))
	}
	return nil
}

func installOne(repo *repoMeta, p pkgMeta) error {
	fmt.Printf("→ %s %s…\n", p.Name, p.Version)
	url := baseURL(repo) + "/" + assetName(p)
	tmp := filepath.Join(cacheDir(), assetName(p))
	if err := download(url, tmp); err != nil {
		return fmt.Errorf("скачивание: %w", err)
	}
	if err := verifyDownload(tmp, p); err != nil {
		_ = os.Remove(tmp)
		return err
	}

	dest := installDest(p)
	_ = os.RemoveAll(dest + ".new")
	if err := os.MkdirAll(filepath.Dir(dest), 0755); err != nil {
		return err
	}

	kind := p.Kind
	if kind == "" {
		kind = "file"
	}

	var err error
	switch kind {
	case "dir":
		err = installDir(p, tmp, dest)
	default: // file — один статический бинарь
		err = installFile(p, tmp)
	}
	if err != nil {
		return err
	}

	_ = os.WriteFile(filepath.Join(stateDir(), p.Name+".ver"), []byte(p.Version+"\n"), 0644)
	fmt.Printf("✓ %s → %s\n", p.Name, checkPath(p))
	return nil
}

// verifyDownload — md5 скачанного архива против индекса. Качаем с curl -k (на станции
// нет CA), так что это единственная проверка, что архив не обрезан и не побит.
func verifyDownload(path string, p pkgMeta) error {
	if p.MD5 == "" {
		return nil
	}
	sum, err := fileMD5(path)
	if err != nil {
		return err
	}
	if strings.EqualFold(sum, p.MD5) {
		return nil
	}
	size := int64(-1)
	if st, err := os.Stat(path); err == nil {
		size = st.Size()
	}
	return fmt.Errorf("%s: md5 %s, а в индексе %s (размер %d, в индексе %d) — архив побит или индекс устарел; повтори «apkg update && apkg install %s» через пару минут",
		assetName(p), sum, p.MD5, size, p.Size, p.Name)
}

// installDir — бандл в opt/<имя>. Прежняя версия ждёт в .old, пока новая не пройдёт
// launchCheck: не запустилась — возвращаем старую (или убираем новую).
func installDir(p pkgMeta, tmp, dest string) error {
	stage := dest + ".new"
	_ = os.MkdirAll(stage, 0755)
	if err := untar(tmp, stage); err != nil {
		_ = os.RemoveAll(stage)
		return err
	}
	// tar может содержать верхнюю папку name/
	src := stage
	if st, err := os.Stat(filepath.Join(stage, p.Name)); err == nil && st.IsDir() {
		src = filepath.Join(stage, p.Name)
	}
	old := dest + ".old"
	_ = os.RemoveAll(old)
	hadOld := false
	if _, err := os.Lstat(dest); err == nil {
		if err := os.Rename(dest, old); err != nil {
			_ = os.RemoveAll(stage)
			return err
		}
		hadOld = true
	}
	if err := os.Rename(src, dest); err != nil {
		_ = os.RemoveAll(stage)
		if hadOld {
			_ = os.Rename(old, dest)
		}
		return err
	}
	_ = os.RemoveAll(stage)
	chmodTree(dest)
	bin := or(p.Bin, p.Name)
	dst := filepath.Join(bindir(), bin)
	_ = os.MkdirAll(bindir(), 0755)
	rollback := func() {
		_ = os.RemoveAll(dest)
		_ = os.Remove(dst)
		if hadOld {
			_ = os.Rename(old, dest)
			_ = writeBoundWrapper(ensureMuslWrapper(dest, bin, p), dest, bin, dst)
		}
	}
	// НЕ symlink: dirname($0) у /system/xbin/btop и bindir-symlink ломает путь.
	// В PATH — обёртка с абсолютным DIR=dest (пакет в opt).
	_ = os.Remove(dst)
	if err := writeBoundWrapper(ensureMuslWrapper(dest, bin, p), dest, bin, dst); err != nil {
		rollback()
		return err
	}
	if err := launchCheck(dst); err != nil {
		rollback()
		return launchFailed(p, hadOld, err)
	}
	_ = os.RemoveAll(old)
	tryXbin(dest, bin)
	if p.Runtime == "musl" || fileExists(filepath.Join(dest, "lib", "ld-musl-aarch64.so.1")) {
		fmt.Printf("  (musl: запускай «%s», не %s/bin/%s)\n", bin, dest, bin)
	}
	return nil
}

// installFile — один бинарь в bindir. Прежний ждёт в .old, пока новый не пройдёт
// launchCheck. Rename вместо перезаписи ещё и потому, что запущенный бинарь (сам apkg
// при «apkg upgrade») поверх не записать — «text file busy».
func installFile(p pkgMeta, tmp string) error {
	_ = os.MkdirAll(bindir(), 0755)
	bin := or(p.Bin, p.Name)
	dst := filepath.Join(bindir(), bin)
	src := tmp
	// если tar — распаковать во временную и найти бинарь;
	// не распаковался — значит, сырой бинарь с расширением .tar по ошибке
	if strings.HasSuffix(tmp, ".tar") || strings.HasSuffix(tmp, ".tar.gz") {
		stage := filepath.Join(cacheDir(), p.Name+"-extract")
		_ = os.RemoveAll(stage)
		_ = os.MkdirAll(stage, 0755)
		if err := untar(tmp, stage); err == nil {
			// tar = name/name (файл). stage/name часто ДИРЕКТОРИЯ — не брать её как бинарь
			cand := ""
			for _, c := range []string{
				filepath.Join(stage, p.Name, bin),
				filepath.Join(stage, bin),
				filepath.Join(stage, p.Name, p.Name),
			} {
				if st, err := os.Stat(c); err == nil && !st.IsDir() {
					cand = c
					break
				}
			}
			if cand == "" {
				_ = filepath.Walk(stage, func(path string, info os.FileInfo, err error) error {
					if err != nil || info.IsDir() {
						return nil
					}
					if info.Name() == bin || (info.Mode()&0111 != 0 && info.Name() == p.Name) {
						cand = path
						return io.EOF
					}
					return nil
				})
			}
			if cand == "" {
				return fmt.Errorf("в %s не найден бинарь %s", assetName(p), bin)
			}
			src = cand
		}
	}
	old := dst + ".old"
	_ = os.Remove(old)
	hadOld := os.Rename(dst, old) == nil
	restore := func() {
		_ = os.Remove(dst)
		if hadOld {
			_ = os.Rename(old, dst)
		}
	}
	if err := copyFile(src, dst); err != nil {
		restore()
		return err
	}
	_ = os.Chmod(dst, 0755)
	if err := launchCheck(dst); err != nil {
		restore()
		return launchFailed(p, hadOld, err)
	}
	_ = os.Remove(old)
	tryXbin(dst, bin)
	return nil
}

// launchCheck — запускается ли установленная команда вообще. Наличие файла (check)
// этого не гарантирует: parallel 20240422 ставился «успешно», а при запуске падал с
// «Not a valid dynamic program». Ошибкой считаем только однозначное: сообщение
// загрузчика или интерпретатора, exit 126/127, падение по сигналу. Код возврата
// --version и таймаут — нет: не все программы знают этот флаг.
func launchCheck(cmdPath string) error {
	if os.Getenv("APKG_NOCHECK") == "1" {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	var out bytes.Buffer
	cmd := exec.CommandContext(ctx, cmdPath, "--version")
	cmd.Stdout = &out
	cmd.Stderr = &out
	cmd.WaitDelay = 2 * time.Second // потомок с нашим stdout не держит проверку вечно
	err := cmd.Run()
	if ctx.Err() != nil {
		return nil // не завершилась за 15 с — значит, запустилась (ждёт ввода, сервер)
	}
	return launchProblem(out.String(), err)
}

// однозначные признаки «программа не стартовала»
var launchFailMarkers = []string{
	"Not a valid dynamic program", // musl: загрузчику дали не ELF (скрипт без интерпретатора)
	"Error loading shared library",
	"Error relocating",
	"cannot open shared object file",
	"CANNOT LINK EXECUTABLE", // bionic
	"Dynamic Program Loader", // ld-musl запущен без программы
	"Can't locate ",          // perl: нет модуля
	"Can't load '",
	"BEGIN failed--compilation aborted",
	"ModuleNotFoundError",
	"Fatal Python error",
}

func launchProblem(out string, err error) error {
	for _, m := range launchFailMarkers {
		if strings.Contains(out, m) {
			return errors.New(firstLines(out, 4))
		}
	}
	if err == nil {
		return nil
	}
	var ee *exec.ExitError
	if !errors.As(err, &ee) {
		return err // не запустилась совсем: нет интерпретатора из #!, exec format error
	}
	if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return fmt.Errorf("упала по сигналу: %v\n%s", ws.Signal(), firstLines(out, 4))
	}
	switch code := ee.ExitCode(); code {
	case 126, 127, 132, 133, 134, 135, 136, 139: // не исполняется / не найдена / сигнал через sh
		return fmt.Errorf("exit %d\n%s", code, firstLines(out, 4))
	}
	return nil
}

func launchFailed(p pkgMeta, restored bool, err error) error {
	what := "установку отменил"
	if restored {
		what = "вернул прежнюю версию"
	}
	return fmt.Errorf("%s %s не запускается — %s:\n%v\n  (проверка после установки отключается APKG_NOCHECK=1)", p.Name, p.Version, what, err)
}

// firstLines — первые n непустых строк с отступом (для сообщений об ошибке)
func firstLines(s string, n int) string {
	var keep []string
	for _, ln := range strings.Split(s, "\n") {
		if ln = strings.TrimSpace(ln); ln != "" {
			keep = append(keep, "  "+ln)
			if len(keep) == n {
				break
			}
		}
	}
	return strings.Join(keep, "\n")
}

func removeOne(p pkgMeta) error {
	kind := p.Kind
	if kind == "" {
		kind = "file"
	}
	bin := or(p.Bin, p.Name)
	_ = os.Remove(filepath.Join(bindir(), bin))
	_ = os.Remove(filepath.Join("/system/xbin", bin))
	if kind == "dir" {
		_ = os.RemoveAll(installDest(p))
	}
	_ = os.Remove(filepath.Join(stateDir(), p.Name+".ver"))
	return nil
}

func installDest(p pkgMeta) string {
	// dest из индекса часто под Android (/data/local/opt/…) —
	// на buildroot подменяем префикс на P.Opt
	if p.Dest != "" {
		return remapDest(p.Dest)
	}
	if p.Kind == "dir" {
		return filepath.Join(optDir(), p.Name)
	}
	return filepath.Join(bindir(), or(p.Bin, p.Name))
}

func remapDest(dest string) string {
	// /data/dropbear оставляем как особый случай на android; на buildroot → opt/dropbear
	if strings.HasPrefix(dest, "/data/local/opt/") {
		return filepath.Join(optDir(), strings.TrimPrefix(dest, "/data/local/opt/"))
	}
	if dest == "/data/dropbear" && P.Flavor == "buildroot" {
		return filepath.Join(optDir(), "dropbear")
	}
	if strings.HasPrefix(dest, "/data/local/bin/") {
		return filepath.Join(bindir(), filepath.Base(dest))
	}
	return dest
}

func checkPath(p pkgMeta) string {
	bin := or(p.Bin, p.Name)
	// установлен = команда в bindir (symlink/wrapper) или check с remap
	if _, err := os.Stat(filepath.Join(bindir(), bin)); err == nil {
		return filepath.Join(bindir(), bin)
	}
	if p.Check != "" {
		return remapDest(p.Check)
	}
	if p.Kind == "dir" {
		d := installDest(p)
		cand := filepath.Join(d, "bin", bin)
		if fileExists(cand) {
			return cand
		}
		return filepath.Join(d, bin)
	}
	return filepath.Join(bindir(), bin)
}

func isInstalled(p pkgMeta) bool {
	_, err := os.Stat(checkPath(p))
	return err == nil
}

func assetName(p pkgMeta) string {
	if p.Asset != "" {
		return p.Asset
	}
	return p.Name + ".tar"
}

func findPkg(repo *repoMeta, name string) *pkgMeta {
	for i := range repo.Packages {
		if repo.Packages[i].Name == name {
			return &repo.Packages[i]
		}
	}
	return nil
}

func loadIndex() (*repoMeta, error) {
	path := filepath.Join(stateDir(), "packages.json")
	b, err := os.ReadFile(path)
	if err != nil {
		return fetchIndex(true)
	}
	var m repoMeta
	if err := json.Unmarshal(b, &m); err != nil {
		return fetchIndex(true)
	}
	return &m, nil
}

func fetchIndex(save bool) (*repoMeta, error) {
	urls := []string{indexURL()}
	for _, u := range indexFallbacks {
		if u != urls[0] {
			urls = append(urls, u)
		}
	}
	var last error
	for _, u := range urls {
		m, b, err := fetchIndexURL(u)
		if err != nil {
			last = err
			fmt.Fprintf(os.Stderr, "  · индекс %s: %v\n", u, err)
			continue
		}
		if save {
			_ = os.WriteFile(filepath.Join(stateDir(), "packages.json"), b, 0644)
		}
		return m, nil
	}
	if last == nil {
		last = fmt.Errorf("все зеркала индекса недоступны")
	}
	return nil, last
}

func fetchIndexURL(u string) (*repoMeta, []byte, error) {
	req, err := http.NewRequest("GET", u, nil)
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("User-Agent", "apkg/"+version)
	res, err := httpClient.Do(req)
	if err != nil {
		// curl с тем же URL (иногда свой DNS/DoH)
		tmp := filepath.Join(cacheDir(), "packages.json.tmp")
		if err2 := downloadCurl(u, tmp); err2 != nil {
			return nil, nil, err
		}
		b, err2 := os.ReadFile(tmp)
		if err2 != nil {
			return nil, nil, err
		}
		var m repoMeta
		if err2 := json.Unmarshal(b, &m); err2 != nil {
			return nil, nil, err2
		}
		return &m, b, nil
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return nil, nil, fmt.Errorf("HTTP %d", res.StatusCode)
	}
	b, err := io.ReadAll(res.Body)
	if err != nil {
		return nil, nil, err
	}
	var m repoMeta
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, nil, err
	}
	return &m, b, nil
}

func download(rawURL, dst string) error {
	fmt.Printf("  ↓ %s\n", rawURL)
	// на колонке системный DNS мёртв (::1:53) — сразу curl -k с --resolve
	if err := downloadCurl(rawURL, dst); err == nil {
		return nil
	} else {
		fmt.Fprintf(os.Stderr, "  · curl: %v — пробую встроенный HTTP\n", err)
	}
	req, err := http.NewRequest("GET", rawURL, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "apkg/"+version)
	res, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return fmt.Errorf("HTTP %d", res.StatusCode)
	}
	f, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(f, res.Body)
	return err
}

func findCurl() string {
	for _, c := range []string{
		filepath.Join(P.Bindir, "curl"),
		"/data/local/bin/curl",
		"/usr/local/bin/curl",
		"/usr/bin/curl",
		"/bin/curl",
	} {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	return "curl"
}

func downloadCurl(rawURL, dst string) error {
	curl := findCurl()
	args := []string{
		"-kfL", // -k обязательно: на станции нет CA
		"--retry", "3",
		"--connect-timeout", "20",
		"--max-time", "300",
		"-o", dst,
	}
	args = append(args, curlResolveFlags(rawURL)...)
	args = append(args, rawURL)
	cmd := exec.Command(curl, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// curlResolveFlags — обход битого resolv.conf: резолвим сами, curl --resolve host:443:ip
func curlResolveFlags(rawURL string) []string {
	hosts := map[string]struct{}{}
	if u, err := url.Parse(rawURL); err == nil && u.Hostname() != "" {
		hosts[u.Hostname()] = struct{}{}
	}
	for _, h := range githubHosts {
		hosts[h] = struct{}{}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	var flags []string
	for h := range hosts {
		ips, err := lookupPreferV4(ctx, h)
		if err != nil || len(ips) == 0 {
			continue
		}
		ip := ips[0]
		flags = append(flags,
			"--resolve", fmt.Sprintf("%s:443:%s", h, ip),
			"--resolve", fmt.Sprintf("%s:80:%s", h, ip),
		)
	}
	return flags
}

func untar(archive, dest string) error {
	_ = os.MkdirAll(dest, 0755)
	// buildroot: обычный tar; android: toybox tar
	var cmd *exec.Cmd
	if P.Flavor == "android" {
		if _, err := exec.LookPath("toybox"); err == nil {
			cmd = exec.Command("toybox", "tar", "-xf", archive, "-C", dest)
		}
	}
	if cmd == nil {
		cmd = exec.Command("tar", "-xf", archive, "-C", dest)
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("tar: %v (%s)", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	_ = os.MkdirAll(filepath.Dir(dst), 0755)
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0755)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}

func fileMD5(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := md5.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func tryXbin(pkgDestOrBin, bin string) {
	// только Android; на buildroot /system нет
	if P.Flavor != "android" {
		return
	}
	if !dirExists("/system/xbin") {
		return
	}
	xbin := filepath.Join("/system/xbin", bin)
	_ = exec.Command("mount", "-o", "remount,rw", "/system").Run()
	_ = os.Remove(xbin)
	// dir-пакет: обёртка с абсолютным DIR; file: копия бинаря
	wrap := filepath.Join(pkgDestOrBin, bin+"-run")
	if !fileExists(wrap) {
		wrap = filepath.Join(pkgDestOrBin, bin+"-ssh")
	}
	if fileExists(wrap) && dirExists(pkgDestOrBin) {
		_ = writeBoundWrapper(wrap, pkgDestOrBin, bin, xbin)
	} else if fileExists(pkgDestOrBin) {
		_ = copyFile(pkgDestOrBin, xbin)
		_ = os.Chmod(xbin, 0755)
	}
	_ = exec.Command("mount", "-o", "remount,ro", "/system").Run()
}

func or(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func chmodTree(root string) {
	_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil
		}
		mode := info.Mode()
		name := info.Name()
		if strings.HasSuffix(name, "-run") || strings.HasSuffix(name, "-ssh") ||
			strings.Contains(path, "/bin/") || strings.HasPrefix(name, "ld-musl") ||
			strings.HasSuffix(name, ".so") || strings.Contains(name, ".so.") {
			_ = os.Chmod(path, mode|0755)
		}
		return nil
	})
}

// ensureMuslWrapper — обёртка в opt; #!/bin/sh + DIR=dirname (в PATH пишется bound).
func ensureMuslWrapper(dest, bin string, p pkgMeta) string {
	for _, name := range []string{bin + "-run", p.Name + "-run", bin + "-ssh", "run.sh"} {
		cand := filepath.Join(dest, name)
		if fileExists(cand) {
			return cand
		}
	}
	relBin := "bin/" + bin
	if !fileExists(filepath.Join(dest, "bin", bin)) && fileExists(filepath.Join(dest, bin)) {
		relBin = bin
	}
	wrap := filepath.Join(dest, bin+"-run")
	body := "#!/bin/sh\n" +
		"DIR=$(CDPATH= cd -- \"$(dirname \"$0\")\" && pwd)\n" +
		"export LD_LIBRARY_PATH=\"$DIR/lib:${LD_LIBRARY_PATH:-}\"\n"
	if fileExists(filepath.Join(dest, "lib", "ld-musl-aarch64.so.1")) {
		body += "exec \"$DIR/lib/ld-musl-aarch64.so.1\" \"$DIR/" + relBin + "\" \"$@\"\n"
	} else if fileExists(filepath.Join(dest, "ld-musl-aarch64.so.1")) {
		body += "export LD_LIBRARY_PATH=\"$DIR:${LD_LIBRARY_PATH:-}\"\n" +
			"exec \"$DIR/ld-musl-aarch64.so.1\" \"$DIR/" + relBin + "\" \"$@\"\n"
	} else {
		body += "exec \"$DIR/" + relBin + "\" \"$@\"\n"
	}
	_ = os.WriteFile(wrap, []byte(body), 0755)
	return wrap
}

// writeBoundWrapper — обёртка в PATH/xbin с абсолютным DIR=пакет (не dirname $0).
func writeBoundWrapper(srcWrap, dest, bin, dst string) error {
	relBin := "bin/" + bin
	if !fileExists(filepath.Join(dest, "bin", bin)) && fileExists(filepath.Join(dest, bin)) {
		relBin = bin
	}
	if b, err := os.ReadFile(srcWrap); err == nil && len(b) > 0 {
		body := string(b)
		// заменяем dirname($0) → абсолютный dest, остальное (btop env) сохраняем
		repl := []string{
			`DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)`,
			`DIR=$(cd "$(dirname "$0")" && pwd)`,
			`DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"`,
		}
		ok := false
		for _, r := range repl {
			if strings.Contains(body, r) {
				body = strings.Replace(body, r, "DIR="+dest, 1)
				ok = true
				break
			}
		}
		if ok || strings.Contains(body, "DIR=") {
			if !ok {
				// уже есть DIR= — переписать первую строку DIR=
				lines := strings.Split(body, "\n")
				for i, ln := range lines {
					if strings.HasPrefix(ln, "DIR=") {
						lines[i] = "DIR=" + dest
						body = strings.Join(lines, "\n")
						break
					}
				}
			}
			return os.WriteFile(dst, []byte(body), 0755)
		}
	}
	out := "#!/bin/sh\nDIR=" + dest + "\n" +
		"export LD_LIBRARY_PATH=\"$DIR/lib:${LD_LIBRARY_PATH:-}\"\n"
	if fileExists(filepath.Join(dest, "lib", "ld-musl-aarch64.so.1")) {
		out += "exec \"$DIR/lib/ld-musl-aarch64.so.1\" \"$DIR/" + relBin + "\" \"$@\"\n"
	} else if fileExists(filepath.Join(dest, "ld-musl-aarch64.so.1")) {
		out += "export LD_LIBRARY_PATH=\"$DIR:${LD_LIBRARY_PATH:-}\"\n" +
			"exec \"$DIR/ld-musl-aarch64.so.1\" \"$DIR/" + relBin + "\" \"$@\"\n"
	} else {
		out += "exec \"$DIR/" + relBin + "\" \"$@\"\n"
	}
	return os.WriteFile(dst, []byte(out), 0755)
}
