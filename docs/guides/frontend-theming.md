# Frontend Theming Guide

**Status:** ACTIVE
**Last Updated:** 2026-01-14

Complete guide for frontend development and theming in NWP with automatic build tool detection and unified workflow.

## Overview

NWP provides a unified frontend development workflow that automatically detects and manages build tools including Gulp, Grunt, Webpack, and Vite. The `theme` command abstracts build tool complexity, providing a consistent interface regardless of the underlying tool.

## Theme Commands

```bash
pl theme setup <sitename>        # Install Node.js dependencies
pl theme watch <sitename>        # Development mode with live reload
pl theme build <sitename>        # Production build (minified)
pl theme dev <sitename>          # Development build (one-time)
pl theme lint <sitename>         # Run linting (ESLint, Stylelint)
pl theme info <sitename>         # Show theme and build tool info
pl theme list <sitename>         # List all themes for site
```

## Supported Build Tools

NWP automatically detects build tools from project files:

| Build Tool | Detection File | Common In |
|------------|----------------|-----------|
| **Gulp** | `gulpfile.js` | OpenSocial, legacy Drupal |
| **Grunt** | `Gruntfile.js` | Vortex, Drupal community standard |
| **Webpack** | `webpack.config.js` | Varbase, modern Drupal |
| **Vite** | `vite.config.js` | Greenfield projects |

## Frontend Workflow

### Step 1: Setup Theme

Install Node.js dependencies:

```bash
pl theme setup avc
```

Process:
1. Auto-detects theme directory
2. Identifies build tool (Gulp/Grunt/Webpack/Vite)
3. Runs `npm install` or `yarn install`
4. Verifies installation

Output:
```
═══════════════════════════════════════════════════════════════
  Theme Setup: avc
═══════════════════════════════════════════════════════════════

Detecting theme...
✓ Theme found: html/themes/custom/socialblue

Detecting build tool...
✓ Build tool: Gulp 4.0.2

Installing dependencies...
✓ npm install complete (234 packages)

Setup complete:
  Theme:      socialblue
  Build tool: Gulp
  Deps:       234 packages
  Ready:      pl theme watch avc
```

### Step 2: Development Mode

Start live reload development:

```bash
pl theme watch avc
```

Features:
- **Live reload** - Browser auto-refreshes on file changes
- **Fast compilation** - Incremental builds
- **Source maps** - Debug compiled code
- **Error reporting** - Real-time error display

Output:
```
═══════════════════════════════════════════════════════════════
  Theme Watch: avc (socialblue)
═══════════════════════════════════════════════════════════════

Starting Gulp watch...

[14:30:22] Starting 'watch'...
[14:30:22] Starting 'compile-sass'...
[14:30:23] Finished 'compile-sass' after 845 ms
[14:30:23] Starting 'compile-js'...
[14:30:24] Finished 'compile-js' after 1.2 s

Watching for changes...
  SCSS:  html/themes/custom/socialblue/scss/**/*.scss
  JS:    html/themes/custom/socialblue/js/**/*.js
  Twig:  html/themes/custom/socialblue/templates/**/*.twig

BrowserSync running:
  Local:     http://localhost:3000
  External:  http://192.168.1.100:3000
  Proxy:     https://avc.ddev.site

Press Ctrl+C to stop
```

### Step 3: Production Build

Create optimized production build:

```bash
pl theme build avc
```

Optimizations:
- **Minification** - CSS and JS minified
- **Concatenation** - Files combined
- **Compression** - Gzip compression
- **Asset optimization** - Images optimized
- **Source map removal** - No source maps in production

Output:
```
═══════════════════════════════════════════════════════════════
  Production Build: avc
═══════════════════════════════════════════════════════════════

Starting production build...

[14:30:22] Starting 'build'...
[14:30:22] Starting 'compile-sass'...
[14:30:24] Finished 'compile-sass' (2.1s)
[14:30:24] Starting 'minify-css'...
[14:30:25] Finished 'minify-css' (845ms)
[14:30:25] Starting 'compile-js'...
[14:30:27] Finished 'compile-js' (1.8s)
[14:30:27] Starting 'minify-js'...
[14:30:28] Finished 'minify-js' (1.2s)
[14:30:28] Starting 'optimize-images'...
[14:30:30] Finished 'optimize-images' (1.5s)

Build complete:
  CSS:    style.min.css (45 KB → 12 KB)
  JS:     script.min.js (134 KB → 48 KB)
  Images: Optimized 23 images (saved 234 KB)
  Total:  7.2 seconds
```

### Step 4: Linting

Run code quality checks:

```bash
pl theme lint avc
```

Checks:
- **ESLint** - JavaScript linting
- **Stylelint** - CSS/SCSS linting
- **Drupal standards** - Drupal coding standards

Output:
```
═══════════════════════════════════════════════════════════════
  Theme Linting: avc
═══════════════════════════════════════════════════════════════

Running ESLint...
✓ 23 files checked, 0 errors, 0 warnings

Running Stylelint...
✓ 45 files checked, 0 errors, 0 warnings

All checks passed ✓
```

## Build Tool Specifics

### Gulp (OpenSocial)

Typical Gulp tasks:
```javascript
// gulpfile.js
gulp.task('compile-sass', ...)
gulp.task('compile-js', ...)
gulp.task('watch', ...)
gulp.task('build', ...)
```

NWP mapping:
- `pl theme watch` → `gulp watch`
- `pl theme build` → `gulp build`
- `pl theme dev` → `gulp compile`

### Grunt (Vortex/Drupal Standard)

Typical Grunt tasks:
```javascript
// Gruntfile.js
grunt.registerTask('default', ['watch']);
grunt.registerTask('build', ['sass', 'concat', 'uglify']);
```

NWP mapping:
- `pl theme watch` → `grunt watch`
- `pl theme build` → `grunt build`

### Webpack (Varbase)

Webpack modes:
```javascript
// webpack.config.js
module.exports = {
  mode: 'development', // or 'production'
  ...
}
```

NWP mapping:
- `pl theme watch` → `webpack --watch --mode=development`
- `pl theme build` → `webpack --mode=production`

### Vite (Modern)

Vite commands:
```javascript
// vite.config.js
export default {
  build: { ... },
  server: { ... }
}
```

NWP mapping:
- `pl theme watch` → `vite`
- `pl theme build` → `vite build`

## Custom Theme Directory

Override auto-detection:

```bash
# Specify theme directory
pl theme watch avc -t /path/to/theme

# Or in nwp.yml
sites:
  avc:
    recipe: os
    frontend:
      theme_path: html/themes/custom/mytheme
```

## Configuration

### Override Build Tool

Configure in `nwp.yml`:

```yaml
sites:
  avc:
    recipe: os
    frontend:
      build_tool: gulp         # Override detection
      package_manager: yarn    # npm or yarn
      node_version: "20"       # Node.js version
      theme_path: html/themes/custom/socialblue
```

### Custom Scripts

Define custom npm scripts:

```json
{
  "scripts": {
    "dev": "gulp watch",
    "build": "gulp build --production",
    "lint": "eslint . && stylelint '**/*.scss'"
  }
}
```

NWP will use these scripts automatically.

## Theme Structure

### OpenSocial Theme (Gulp)

```
html/themes/custom/socialblue/
├── gulpfile.js
├── package.json
├── scss/
│   ├── base/
│   ├── components/
│   └── style.scss
├── js/
│   ├── components/
│   └── script.js
├── templates/
├── dist/
│   ├── css/
│   └── js/
└── assets/
    └── images/
```

### Standard Drupal Theme (Grunt)

```
web/themes/custom/mytheme/
├── Gruntfile.js
├── package.json
├── sass/
│   └── style.scss
├── js/
│   └── script.js
├── templates/
└── dist/
```

## Best Practices

### Development Workflow

1. **Start watch mode**
   ```bash
   pl theme watch avc
   ```

2. **Make changes** in `scss/` or `js/`

3. **Browser auto-refreshes** with BrowserSync

4. **Lint before committing**
   ```bash
   pl theme lint avc
   ```

5. **Production build before deployment**
   ```bash
   pl theme build avc
   ```

### Production Deployment

Before deploying:

```bash
# Production build
pl theme build avc

# Verify build output
ls -lh sites/avc/html/themes/custom/socialblue/dist/

# Commit built assets
git add sites/avc/html/themes/custom/socialblue/dist/
git commit -m "Production build"

# Deploy
pl dev2stg avc
pl stg2prod avc
```

### Git Strategy

**Option 1: Commit built assets**
- Commit `dist/` directory
- Simple deployment
- Larger repository

**Option 2: Build during deployment**
- Ignore `dist/` directory
- Run `pl theme build` during deployment
- Smaller repository
- Requires Node.js on server

## Troubleshooting

### Node Modules Not Found

**Symptom:**
```
ERROR: Cannot find module 'gulp'
```

**Solution:**
```bash
# Reinstall dependencies
pl theme setup avc

# Or manually
cd sites/avc/html/themes/custom/socialblue/
npm install
```

### Build Tool Not Detected

**Symptom:**
```
ERROR: No build tool detected
```

**Solution:**
- Verify build file exists (`gulpfile.js`, etc.)
- Specify manually in `nwp.yml`
- Check theme path is correct

### BrowserSync Not Working

**Symptom:**
Browser not auto-refreshing

**Solution:**
```bash
# Check BrowserSync configuration in gulpfile.js
# Verify proxy setting matches DDEV site
# Try manual refresh

# Restart watch
pl theme watch avc
```

### Compilation Errors

**Symptom:**
```
ERROR: Sass compilation failed
```

**Solution:**
- Check syntax errors in SCSS files
- Verify imports are correct
- Check Node.js version compatibility
- Review error message for line number

## Related Commands

- [theme](../reference/commands/theme.md) - Theme command reference
- [make](../reference/commands/make.md) - Toggle dev/prod mode
- [dev2stg](../reference/commands/dev2stg.md) - Deploy with frontend build

## See Also

- [Frontend Libraries](../../lib/frontend/) - Build tool implementations
- [Gulp Documentation](https://gulpjs.com/) - Gulp official docs
- [Webpack Documentation](https://webpack.js.org/) - Webpack official docs
- [Vite Documentation](https://vitejs.dev/) - Vite official docs
