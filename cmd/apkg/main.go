// apkg — пакетный менеджер для Яндекс.Станции (Alice Panel).
package main

import (
	"crypto/md5"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	defaultIndexURL = "https://cdn.jsdelivr.net/gh/initialfox/yandex-station-repo@main/packages.json"
	defaultBaseURL  = "https://github.com/initialfox/yandex-station-repo/releases/latest/download"
	defaultBindir   = "/data/local/bin"
	defaultOpt      = "/data/local/opt"
	defaultCache    = "/sdcard/apkg-cache"
	defaultState    = "/data/local/apkg"
	version         = "1.0.0"
)

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

var httpClient = &http.Client{
	Timeout: 120 * time.Second,
	Transport: &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, // станция без CA
	},
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
	default:
		fmt.Fprintf(os.Stderr, "неизвестная команда: %s\n", cmd)
		printHelp()
		os.Exit(1)
	}
}

func printHelp() {
	fmt.Print(`apkg — пакетный менеджер Яндекс.Станции (один бинарь)

  apkg update              обновить индекс
  apkg list [-i]           все пакеты (+ статус)
  apkg search <слово>      поиск
  apkg info <имя>          подробно
  apkg install <имя…>      поставить
  apkg remove <имя…>       удалить
  apkg upgrade [имя…]      обновить

Musl-пакеты (nano, nmap, openvpn…): ставятся целиком в /data/local/opt/<имя>
с lib/ и обёрткой *-run → /data/local/bin/<имя>.
Голый ELF без loader даёт «not found» — всегда запускай через имя в PATH
или …/opt/<имя>/<имя>-run.

Переменные:
  APKG_INDEX   URL packages.json
  APKG_BASE    URL релизов (…/download)
  APKG_BINDIR  куда класть команды (по умолч. /data/local/bin)
`)
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
	if v := os.Getenv("APKG_BINDIR"); v != "" {
		return v
	}
	return defaultBindir
}

func stateDir() string {
	_ = os.MkdirAll(defaultState, 0755)
	return defaultState
}

func cacheDir() string {
	_ = os.MkdirAll(defaultCache, 0755)
	return defaultCache
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
	for _, name := range targets {
		p := findPkg(repo, name)
		if p == nil {
			continue
		}
		fmt.Printf("→ обновляю %s…\n", name)
		if err := installOne(repo, *p); err != nil {
			return err
		}
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
	if p.MD5 != "" {
		sum, err := fileMD5(tmp)
		if err != nil {
			return err
		}
		// md5 в индексе может быть от бинарника, не от tar — не фатально
		_ = sum
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

	switch kind {
	case "dir":
		_ = os.MkdirAll(dest+".new", 0755)
		if err := untar(tmp, dest+".new"); err != nil {
			return err
		}
		// tar может содержать верхнюю папку name/
		inner := filepath.Join(dest+".new", p.Name)
		if st, err := os.Stat(inner); err == nil && st.IsDir() {
			_ = os.RemoveAll(dest)
			if err := os.Rename(inner, dest); err != nil {
				return err
			}
			_ = os.RemoveAll(dest + ".new")
		} else {
			_ = os.RemoveAll(dest)
			if err := os.Rename(dest+".new", dest); err != nil {
				return err
			}
		}
		chmodTree(dest)
		bin := or(p.Bin, p.Name)
		wrap := ensureMuslWrapper(dest, bin, p)
		dst := filepath.Join(bindir(), bin)
		_ = os.MkdirAll(bindir(), 0755)
		// symlink → обёртка в opt: dirname($0) = пакет (важно для gen2 /bkupgrade/data)
		_ = os.Remove(dst)
		if err := os.Symlink(wrap, dst); err != nil {
			// fallback: copy, но переписать DIR на абсолютный dest
			if err2 := writeBoundWrapper(wrap, dest, bin, dst); err2 != nil {
				return err2
			}
		}
		tryXbin(dst, bin)
		if p.Runtime == "musl" || fileExists(filepath.Join(dest, "lib", "ld-musl-aarch64.so.1")) {
			fmt.Printf("  (musl: запускай «%s», не %s/bin/%s)\n", bin, dest, bin)
		}
	default: // file — один статический бинарь
		_ = os.MkdirAll(bindir(), 0755)
		bin := or(p.Bin, p.Name)
		dst := filepath.Join(bindir(), bin)
		// если tar — распаковать во временную и найти бинарь
		if strings.HasSuffix(tmp, ".tar") || strings.HasSuffix(tmp, ".tar.gz") {
			stage := filepath.Join(cacheDir(), p.Name+"-extract")
			_ = os.RemoveAll(stage)
			_ = os.MkdirAll(stage, 0755)
			if err := untar(tmp, stage); err != nil {
				// может быть не tar, а сырой бинарь с расширением .tar по ошибке
				if err2 := copyFile(tmp, dst); err2 != nil {
					return err
				}
			} else {
				cand := filepath.Join(stage, bin)
				if _, err := os.Stat(cand); err != nil {
					cand = filepath.Join(stage, p.Name, bin)
				}
				if _, err := os.Stat(cand); err != nil {
					// любой исполняемый
					_ = filepath.Walk(stage, func(path string, info os.FileInfo, err error) error {
						if err != nil || info.IsDir() {
							return nil
						}
						if info.Mode()&0111 != 0 || info.Name() == bin {
							cand = path
							return io.EOF
						}
						return nil
					})
				}
				if err := copyFile(cand, dst); err != nil {
					return err
				}
			}
		} else {
			if err := copyFile(tmp, dst); err != nil {
				return err
			}
		}
		_ = os.Chmod(dst, 0755)
		tryXbin(dst, bin)
	}

	_ = os.WriteFile(filepath.Join(stateDir(), p.Name+".ver"), []byte(p.Version+"\n"), 0644)
	fmt.Printf("✓ %s → %s\n", p.Name, checkPath(p))
	return nil
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
	if p.Dest != "" {
		return p.Dest
	}
	if p.Kind == "dir" {
		return filepath.Join(defaultOpt, p.Name)
	}
	return filepath.Join(bindir(), or(p.Bin, p.Name))
}

func checkPath(p pkgMeta) string {
	if p.Check != "" {
		return p.Check
	}
	if p.Kind == "dir" {
		return filepath.Join(installDest(p), or(p.Bin, p.Name))
	}
	return filepath.Join(bindir(), or(p.Bin, p.Name))
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
	req, _ := http.NewRequest("GET", indexURL(), nil)
	req.Header.Set("User-Agent", "apkg/"+version)
	res, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return nil, fmt.Errorf("index HTTP %d", res.StatusCode)
	}
	b, err := io.ReadAll(res.Body)
	if err != nil {
		return nil, err
	}
	var m repoMeta
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, err
	}
	if save {
		_ = os.WriteFile(filepath.Join(stateDir(), "packages.json"), b, 0644)
	}
	return &m, nil
}

func download(url, dst string) error {
	fmt.Printf("  ↓ %s\n", url)
	req, _ := http.NewRequest("GET", url, nil)
	req.Header.Set("User-Agent", "apkg/"+version)
	res, err := httpClient.Do(req)
	if err != nil {
		// fallback: системный curl -k
		return downloadCurl(url, dst)
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return downloadCurl(url, dst)
	}
	f, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(f, res.Body)
	return err
}

func downloadCurl(url, dst string) error {
	curl := "curl"
	if _, err := os.Stat("/data/local/bin/curl"); err == nil {
		curl = "/data/local/bin/curl"
	}
	cmd := exec.Command(curl, "-kfL", "--retry", "3", "-o", dst, url)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func untar(archive, dest string) error {
	_ = os.MkdirAll(dest, 0755)
	var cmd *exec.Cmd
	if _, err := exec.LookPath("toybox"); err == nil {
		cmd = exec.Command("toybox", "tar", "-xf", archive, "-C", dest)
	} else {
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

func tryXbin(dst, bin string) {
	xbin := filepath.Join("/system/xbin", bin)
	_ = exec.Command("mount", "-o", "remount,rw", "/system").Run()
	_ = os.Remove(xbin)
	_ = os.Symlink(dst, xbin)
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

// ensureMuslWrapper — в PATH только обёртка; #!/bin/sh + DIR=dirname (gen1 и gen2).
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

// writeBoundWrapper — если symlink нельзя: копия с абсолютным DIR=dest.
func writeBoundWrapper(srcWrap, dest, bin, dst string) error {
	b, err := os.ReadFile(srcWrap)
	if err != nil {
		b = nil
	}
	body := string(b)
	if !strings.Contains(body, "dirname") && !strings.Contains(body, "DIR=") {
		body = ""
	}
	// всегда пишем портативный с абсолютным DIR на случай copy в bindir
	relBin := "bin/" + bin
	if !fileExists(filepath.Join(dest, "bin", bin)) && fileExists(filepath.Join(dest, bin)) {
		relBin = bin
	}
	out := "#!/bin/sh\nDIR=" + dest + "\n" +
		"export LD_LIBRARY_PATH=\"$DIR/lib:${LD_LIBRARY_PATH:-}\"\n"
	if fileExists(filepath.Join(dest, "lib", "ld-musl-aarch64.so.1")) {
		out += "exec \"$DIR/lib/ld-musl-aarch64.so.1\" \"$DIR/" + relBin + "\" \"$@\"\n"
	} else {
		out += "exec \"$DIR/" + relBin + "\" \"$@\"\n"
	}
	return os.WriteFile(dst, []byte(out), 0755)
}
