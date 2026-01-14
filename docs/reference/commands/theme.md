# theme

**Last Updated:** 2026-01-14

Unified frontend build tool management for Drupal themes with support for Gulp, Grunt, Webpack, and Vite.

## Overview

The `theme` command provides a unified interface for managing frontend build tools across different Drupal themes. It automatically detects the build tool (Gulp, Grunt, Webpack, Vite) and provides consistent commands for setup, development, building, and linting regardless of the underlying tool.

## Synopsis

```bash
pl theme <subcommand> <sitename> [options]
```

## Subcommands

| Subcommand | Description |
|------------|-------------|
| `setup <sitename>` | Install Node.js dependencies for theme |
| `watch <sitename>` | Start development mode with live reload |
| `build <sitename>` | Production build (minified, optimized) |
| `dev <sitename>` | Development build (one-time, with source maps) |
| `lint <sitename>` | Run linting (ESLint, Stylelint) |
| `info <sitename>` | Show theme and build tool information |
| `list <sitename>` | List all themes for a site |

## Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message |
| `-t, --theme <path>` | Specify theme directory (overrides auto-detection) |
| `-d, --debug` | Enable debug output |

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `sitename` | Yes | Site identifier for theme operations |

## Examples

### Install Dependencies

```bash
pl theme setup avc
```

Install Node.js dependencies (npm/yarn install) for the theme.

### Start Development Watch Mode

```bash
pl theme watch avc
```

Start watch mode with live reload and auto-compilation.

### Production Build

```bash
pl theme build avc
```

Build optimized assets for production (minified, compressed).

### Development Build

```bash
pl theme dev avc
```

One-time development build with source maps.

### Run Linting

```bash
pl theme lint avc
```

Run ESLint and Stylelint on theme code.

### Show Theme Information

```bash
pl theme info avc
```

Display detected build tool, configuration files, and npm scripts.

### List All Themes

```bash
pl theme list avc
```

Show all themes with package.json found for the site.

### Use Specific Theme Directory

```bash
pl theme watch avc -t /path/to/custom/theme
```

Override auto-detection and use specified theme directory.

### Short Aliases

```bash
pl theme w avc    # watch
pl theme b avc    # build
pl theme d avc    # dev
pl theme l avc    # lint
pl theme i avc    # info
```

## Build Tool Auto-Detection

The command automatically detects the build tool based on project files:

| File | Build Tool | Common In |
|------|------------|-----------|
| `gulpfile.js` | Gulp | OpenSocial, legacy Drupal |
| `Gruntfile.js` | Grunt | Vortex, Drupal standard |
| `webpack.config.js` | Webpack | Varbase, modern Drupal |
| `vite.config.js` | Vite | Greenfield projects |

## Supported Build Tools

### Gulp

**Used by:** OpenSocial themes (socialbase, socialblue)

**Common tasks:**
- `gulp watch` - Watch mode
- `gulp build` - Production build
- `gulp` - Default task

### Grunt

**Used by:** Vortex theme, Drupal community standard

**Common tasks:**
- `grunt watch` - Watch mode
- `grunt build` - Production build
- `grunt lint` - Run linters

### Webpack

**Used by:** Varbase theme, modern Drupal setups

**Common tasks:**
- `webpack --watch` - Watch mode
- `webpack --mode production` - Production build
- `webpack --mode development` - Development build

### Vite

**Used by:** Latest/fastest option for new projects

**Common tasks:**
- `vite` - Development server
- `vite build` - Production build

## Configuration

Override auto-detection in `cnwp.yml`:

```yaml
sites:
  mysite:
    recipe: os
    frontend:
      build_tool: gulp           # gulp, grunt, webpack, vite
      package_manager: yarn      # npm, yarn, pnpm
      node_version: "20"         # Minimum Node.js version
      theme_path: "custom/mytheme"  # Relative to web/themes
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error (theme not found, build failed, dependencies missing) |

## Prerequisites

- Node.js installed (version 16+ recommended)
- npm or yarn package manager
- Theme with `package.json` file
- Build tool configuration file (gulpfile.js, etc.)

### Installing Node.js

```bash
# Using nvm (recommended)
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash
nvm install 20
nvm use 20

# Ubuntu/Debian
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# macOS
brew install node
```

## Theme Directory Detection

The command searches for themes in order:

1. **Explicit path** (if provided via `-t` option)
2. **cnwp.yml frontend.theme_path** (if configured)
3. **Active Drupal theme** (via drush)
4. **Custom themes directory**: `sites/<sitename>/web/themes/custom/`
5. **Contrib themes directory**: `sites/<sitename>/web/themes/contrib/`

## Troubleshooting

### Theme Not Found

**Symptom:** "No theme directory found for site"

**Solution:**
```bash
# List available themes
pl theme list mysite

# Show theme search paths
pl theme info mysite

# Specify theme manually
pl theme watch mysite -t /path/to/theme
```

### Build Tool Not Detected

**Symptom:** "No build tool detected in: /path/to/theme"

**Solution:**
1. Verify configuration file exists:
```bash
ls -la /path/to/theme/gulpfile.js
ls -la /path/to/theme/webpack.config.js
```

2. Add configuration file if missing
3. Override in cnwp.yml:
```yaml
sites:
  mysite:
    frontend:
      build_tool: webpack
```

### Dependencies Not Installed

**Symptom:** Build fails with "module not found" errors

**Solution:**
```bash
# Install dependencies
pl theme setup mysite

# Or manually
cd sites/mysite/web/themes/custom/mytheme
npm install
```

### Wrong Node.js Version

**Symptom:** "Node.js X+ required (current: vY)"

**Solution:**
```bash
# Using nvm
nvm install 20
nvm use 20

# Verify
node -v
```

### Build Fails with Error

**Symptom:** Watch or build command fails

**Solution:**
1. Check Node.js version: `node -v`
2. Clear node_modules and reinstall:
```bash
cd /path/to/theme
rm -rf node_modules package-lock.json
npm install
```
3. Check for deprecated packages
4. Review build tool logs for specific errors

### Watch Mode Not Reloading

**Symptom:** Changes not triggering rebuild

**Solution:**
1. Verify file watch limits (Linux):
```bash
echo fs.inotify.max_user_watches=524288 | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```
2. Check watch configuration in gulpfile/webpack.config
3. Restart watch mode
4. Clear browser cache

### Linting Errors

**Symptom:** Lint command shows many errors

**Solution:**
```bash
# Auto-fix where possible
cd /path/to/theme
npx eslint --fix .
npx stylelint --fix "**/*.scss"

# Or update linting rules
# Edit .eslintrc.json or .stylelintrc.json
```

## Best Practices

### Development Workflow

```bash
# 1. Setup (first time only)
pl theme setup mysite

# 2. Start watch mode
pl theme watch mysite

# 3. Make changes in theme files
# (watch mode auto-recompiles)

# 4. Lint before committing
pl theme lint mysite

# 5. Production build for deployment
pl theme build mysite
```

### Version Control

```gitignore
# .gitignore for themes
node_modules/
dist/
build/
*.css.map
*.js.map
```

### Performance

```bash
# Development: Fast builds, source maps
pl theme dev mysite

# Production: Minified, optimized
pl theme build mysite
```

### Package Manager Choice

```yaml
# yarn (faster, deterministic)
frontend:
  package_manager: yarn

# npm (default, widely used)
frontend:
  package_manager: npm

# pnpm (most efficient disk usage)
frontend:
  package_manager: pnpm
```

## Automation Examples

### Build All Themes

```bash
#!/bin/bash
for site in avc nwp mysite; do
  echo "Building theme for $site..."
  pl theme build "$site"
done
```

### Pre-Deployment Hook

```bash
#!/bin/bash
# .git/hooks/pre-commit
echo "Running theme linting..."
if ! pl theme lint mysite; then
  echo "Linting failed. Commit aborted."
  exit 1
fi
```

### CI/CD Pipeline

```yaml
# .gitlab-ci.yml
build-theme:
  stage: build
  script:
    - nvm use 20
    - pl theme setup mysite
    - pl theme lint mysite
    - pl theme build mysite
  artifacts:
    paths:
      - sites/mysite/web/themes/custom/*/dist/
```

## Advanced Usage

### Custom Theme Path

```yaml
# cnwp.yml
sites:
  mysite:
    frontend:
      theme_path: "profiles/custom/myprofile/themes/mytheme"
```

### Multiple Themes

```bash
# Build specific theme
pl theme build mysite -t /path/to/admin-theme
pl theme build mysite -t /path/to/public-theme
```

### Watching Multiple Themes

```bash
# Terminal 1
pl theme watch mysite -t /path/to/theme1

# Terminal 2
pl theme watch mysite -t /path/to/theme2
```

## Notes

- Theme command delegates to tool-specific libraries in `lib/frontend/`
- Auto-detection checks for configuration files in theme directory
- Watch mode blocks terminal (use Ctrl+C to stop)
- Production builds typically take longer but produce smaller files
- Source maps are included in dev builds, excluded in production
- Package manager (npm/yarn) is also auto-detected
- Node.js version requirements vary by build tool
- DDEV integration detects DDEV URLs automatically

## Performance Considerations

- **Gulp**: Fast incremental builds, mature ecosystem
- **Webpack**: Powerful but slower, better for complex apps
- **Vite**: Fastest development server, instant HMR
- **Grunt**: Slower than Gulp, less common in new projects

Build times (typical theme):
- **Watch mode compilation**: 0.5-3 seconds
- **Development build**: 5-30 seconds
- **Production build**: 30-120 seconds

## Security Implications

- npm packages may contain vulnerabilities (audit regularly)
- Lock files (package-lock.json, yarn.lock) ensure reproducible builds
- `node_modules/` should never be committed to git
- Build output (dist/) should be git-ignored for source, included for distribution
- Audit dependencies: `npm audit` or `yarn audit`
- Update dependencies regularly for security patches

## Related Commands

- [develop.sh](develop.md) - Start local development environment
- [drush.sh](drush.md) - Drupal command-line operations
- [test.sh](test.md) - Run test suite

## See Also

- [Frontend Development Guide](../../guides/frontend-development.md) - Complete frontend workflow
- [Theme Development](../../guides/theme-development.md) - Creating custom themes
- [Build Tools Comparison](../../decisions/0008-frontend-build-tools.md) - Build tool architecture
- [OpenSocial Theme Guide](../../guides/opensocial-theming.md) - OpenSocial-specific theming
- [Varbase Theme Guide](../../guides/varbase-theming.md) - Varbase-specific theming
- [Node.js Version Management](../../guides/nodejs-management.md) - Managing Node.js versions
