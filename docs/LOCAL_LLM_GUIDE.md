# Local LLM Guide - Running Open Source AI Models

**Last Updated:** January 10, 2026

A comprehensive guide to running open source AI models locally for privacy, cost savings, and offline development.

---

## Table of Contents

- [Why Use Local LLMs?](#why-use-local-llms)
- [Quick Start with Ollama](#quick-start-with-ollama)
- [Hardware Requirements](#hardware-requirements)
- [Model Selection Guide](#model-selection-guide)
- [Installation Guides](#installation-guides)
- [Privacy Comparison](#privacy-comparison)
- [Cost Analysis](#cost-analysis)
- [Alternative Platforms](#alternative-platforms)
- [Using with NWP](#using-with-nwp)
- [Troubleshooting](#troubleshooting)
- [Advanced Topics](#advanced-topics)

---

## Why Use Local LLMs?

### Benefits

| Benefit | Description |
|---------|-------------|
| **Privacy** | All processing happens on your machine - no data sent to third parties |
| **Cost** | Free after initial setup (no per-token API costs) |
| **Offline** | Works without internet connection |
| **Control** | Choose models, update schedule, customization |
| **Speed** | No network latency (if you have good hardware) |
| **Learning** | Understand how AI models work |

### Trade-offs

| Factor | Cloud API (Claude) | Local LLM |
|--------|-------------------|-----------|
| **Quality** | Excellent | Good to Very Good |
| **Speed** | Fast | Depends on hardware |
| **Setup** | API key only | Install + download models |
| **Cost** | $3-15 per million tokens | Free (after hardware) |
| **Privacy** | Data sent to Anthropic | Complete privacy |
| **Maintenance** | None | Update models yourself |
| **Hardware** | Not needed | 16GB+ RAM recommended |

---

## Quick Start with Ollama

**Ollama is the easiest way to get started with local LLMs.** It's like Docker for AI models.

### 1. Install Ollama

**Linux:**
```bash
curl -fsSL https://ollama.com/install.sh | sh
```

**macOS:**
```bash
# Download from https://ollama.com/download
# Or use Homebrew:
brew install ollama
```

**Windows:**
Download installer from https://ollama.com/download

### 2. Start Ollama Service

**Linux/macOS:**
```bash
# Ollama starts automatically as a service
# Or manually:
ollama serve
```

**Windows:**
The service starts automatically after installation.

### 3. Download and Run Your First Model

**Start with a coding model (recommended for NWP work):**
```bash
# Download and run qwen2.5-coder (7B parameters, good quality)
ollama run qwen2.5-coder:7b
```

**Wait for download to complete** (about 4.7GB):
```
pulling manifest
pulling 8a9a5e4f6fb8... 100% ▕████████████████▏ 4.7 GB
pulling 5c96f5a42c9e... 100% ▕████████████████▏  108 B
pulling b837481ff855... 100% ▕████████████████▏   11 KB
pulling c915be0f8e81... 100% ▕████████████████▏  487 B
verifying sha256 digest
writing manifest
success
```

**Test it:**
```
>>> Write a bash function to check if a file exists

Here's a bash function that checks if a file exists:

```bash
check_file_exists() {
    local file="$1"

    if [[ -f "$file" ]]; then
        echo "File '$file' exists"
        return 0
    else
        echo "File '$file' does not exist"
        return 1
    fi
}
```

Usage example:
```bash
check_file_exists "/path/to/file.txt"
```

>>> /bye
```

**That's it!** You're now running a local AI model.

### 4. Basic Ollama Commands

```bash
# List installed models
ollama list

# Run a specific model
ollama run qwen2.5-coder:7b

# Pull a model without running
ollama pull llama3.2

# Remove a model
ollama rm llama3.2

# Show model information
ollama show qwen2.5-coder:7b

# Update all models
ollama pull --all
```

### 5. Using Ollama as an API

Ollama provides an OpenAI-compatible API:

```bash
# Start the server (usually already running)
ollama serve

# Use the API
curl http://localhost:11434/api/generate -d '{
  "model": "qwen2.5-coder:7b",
  "prompt": "Write a bash function to check if a file exists",
  "stream": false
}'
```

**Integrate with other tools:**
- Aider: `aider --model ollama/qwen2.5-coder:7b`
- Continue.dev (VSCode)
- Open Interpreter: `interpreter --model ollama/qwen2.5-coder:7b`

---

## Hardware Requirements

### Minimum Requirements by Model Size

| Model Size | RAM Needed | GPU | CPU | Speed | Quality |
|------------|------------|-----|-----|-------|---------|
| 1B-3B | 8 GB | No | Any modern | Fast | Basic |
| 7B-8B | 16 GB | Optional | i5/Ryzen 5+ | Good | Good |
| 13B-14B | 32 GB | Recommended | i7/Ryzen 7+ | Slow | Very Good |
| 32B-34B | 64 GB | Yes | i9/Ryzen 9+ | Slow | Excellent |
| 70B+ | 128 GB | Yes (24GB+) | High-end | Very Slow | Excellent |

### Understanding Quantization

**Quantization** reduces model size and RAM requirements with minimal quality loss:

| Format | Size | RAM Usage | Quality Loss |
|--------|------|-----------|--------------|
| **Q4_0** | 1/4 original | ~25% | Small |
| **Q5_0** | 1/3 original | ~30% | Minimal |
| **Q8_0** | 1/2 original | ~50% | Negligible |
| **FP16** | Full size | 100% | None |

**Example:** Llama 3.2 70B model
- FP16 (full): ~140GB RAM required
- Q8_0 (8-bit): ~70GB RAM required
- Q4_0 (4-bit): ~40GB RAM required ✅ Most common

**Most Ollama models use Q4 quantization by default** - good balance of quality and efficiency.

### Check Your Current Hardware

**Linux:**
```bash
# Check RAM
free -h

# Check CPU
lscpu | grep "Model name"
cat /proc/cpuinfo | grep "model name" | head -1

# Check GPU (NVIDIA)
nvidia-smi

# Check disk space
df -h ~
```

**macOS:**
```bash
# Check RAM
sysctl hw.memsize | awk '{print $2/1024/1024/1024 " GB"}'

# Check CPU
sysctl -n machdep.cpu.brand_string

# Check disk space
df -h ~
```

**Windows:**
```powershell
# Check RAM
Get-WmiObject -Class Win32_ComputerSystem | Select-Object TotalPhysicalMemory

# Check CPU
Get-WmiObject -Class Win32_Processor | Select-Object Name

# Check GPU
nvidia-smi  # If NVIDIA GPU installed
```

### Hardware Recommendations

#### Budget Option ($0 - Try Your Current Machine)

**Minimum Specs:**
- 16GB RAM
- Any modern CPU (2020+)
- 50GB free disk space
- No GPU needed

**What you can run:**
- qwen2.5-coder:3b (fast, basic quality)
- qwen2.5-coder:7b (slower, good quality)
- llama3.2:3b (general purpose)

**Speed:** Acceptable for occasional use

#### Mid-Range ($100-200 Upgrade)

**Upgrade Your Current Machine:**
- Add RAM to 32GB
- Keep existing CPU/GPU

**What you can run:**
- qwen2.5-coder:14b (better quality)
- deepseek-coder:6.7b (good for code)
- llama3.2:8b (general purpose)

**Speed:** Good for regular development

#### High-End ($1500-2500 New Workstation)

**Build or Buy:**
- 64GB RAM
- AMD Ryzen 9 / Intel i9
- NVIDIA RTX 4060 Ti or 4070 (16GB VRAM)
- 1TB NVMe SSD

**What you can run:**
- qwen2.5-coder:32b (excellent quality)
- Any 7B-14B model (very fast)
- Multiple models

**Speed:** Fast enough for constant use

#### Enthusiast ($3000-5000 Dedicated AI Workstation)

**Specs:**
- 128GB+ RAM
- AMD Threadripper / Intel Xeon
- NVIDIA RTX 4090 (24GB VRAM) or A5000
- 2TB+ NVMe SSD

**What you can run:**
- Any model up to 70B
- Multiple models simultaneously
- Fine-tuning and training

**Speed:** Comparable to cloud APIs

---

## Model Selection Guide

### Best Models for Different Tasks

#### Coding (Bash, PHP, Drupal Development)

| Model | Size | Quality | Speed (16GB RAM) | Best For |
|-------|------|---------|------------------|----------|
| **qwen2.5-coder:3b** | 3B | Good | Very Fast | Quick scripts, simple tasks |
| **qwen2.5-coder:7b** | 7B | Very Good | Good | General coding (RECOMMENDED) |
| **qwen2.5-coder:14b** | 14B | Excellent | Slow | Complex code, refactoring |
| **qwen2.5-coder:32b** | 32B | Excellent | Very Slow (needs 64GB) | Professional work |
| **deepseek-coder-v2:16b** | 16B | Excellent | Slow | Multi-language coding |
| **codestral:22b** | 22B | Excellent | Very Slow (needs 32GB) | Advanced coding tasks |

**For NWP development (bash/PHP/Drupal):**
→ **Start with `qwen2.5-coder:7b`** - best balance of quality and speed

#### General Purpose (Chat, Q&A, Explanations)

| Model | Size | Quality | Speed | Best For |
|-------|------|---------|-------|----------|
| **llama3.2:3b** | 3B | Good | Very Fast | Quick questions |
| **llama3.2:8b** | 8B | Very Good | Good | General use |
| **llama3.1:70b** | 70B | Excellent | Very Slow | Complex reasoning |
| **mistral:7b** | 7B | Very Good | Good | Fast general purpose |
| **phi3:3.8b** | 3.8B | Good | Very Fast | Efficient, small |

**For general Q&A:**
→ **`llama3.2:8b`** or **`mistral:7b`**

#### Specialized Models

| Model | Purpose |
|-------|---------|
| **nous-hermes2:latest** | Instruction following, creative writing |
| **dolphin-mixtral:latest** | Uncensored, technical tasks |
| **wizardlm2:7b** | Complex reasoning |
| **solar:10.7b** | Korean/multilingual |

### Download Models

```bash
# Coding models
ollama pull qwen2.5-coder:7b      # Recommended for coding
ollama pull qwen2.5-coder:3b      # Smaller, faster
ollama pull deepseek-coder-v2:16b # Advanced coding

# General purpose
ollama pull llama3.2:8b           # Recommended general use
ollama pull mistral:7b            # Fast alternative
ollama pull phi3:3.8b             # Very small, efficient

# List all available models
# Visit: https://ollama.com/library
```

### Model Comparison Example

Let's compare three models on the same task: "Write a bash function to check if a file exists"

**qwen2.5-coder:3b (Fast, Basic):**
- Response time: 2 seconds
- Quality: Correct, basic implementation
- Use when: Speed matters, simple tasks

**qwen2.5-coder:7b (Balanced, RECOMMENDED):**
- Response time: 5 seconds
- Quality: Correct, with error handling and comments
- Use when: Need good quality, acceptable speed

**qwen2.5-coder:32b (Slow, Excellent):**
- Response time: 20 seconds (needs 64GB RAM)
- Quality: Excellent, multiple approaches, edge cases
- Use when: Complex problems, quality critical

---

## Installation Guides

### Ollama (Recommended)

**Pros:**
- Easiest to use
- Automatic model management
- Built-in API server
- Good performance

**Installation:**
```bash
# Linux
curl -fsSL https://ollama.com/install.sh | sh

# macOS
brew install ollama
# Or download from https://ollama.com/download

# Windows
# Download installer from https://ollama.com/download
```

**Usage:**
```bash
ollama run qwen2.5-coder:7b
```

**Documentation:** https://github.com/ollama/ollama

---

### LM Studio (GUI, Beginner-Friendly)

**Pros:**
- Point-and-click interface
- Built-in model browser
- Easy to try different models
- Cross-platform (Mac, Windows, Linux)

**Installation:**
1. Download from https://lmstudio.ai/
2. Install and launch
3. Browse models in "Discover" tab
4. Download a model (click download icon)
5. Load model and start chatting

**Best for:** Beginners, experimenting with different models

---

### llama.cpp (Advanced, Maximum Control)

**Pros:**
- Fastest inference
- Most control over parameters
- CPU-optimized
- Lightweight

**Installation:**
```bash
# Clone repository
git clone https://github.com/ggerganov/llama.cpp
cd llama.cpp

# Build
make

# Or with GPU support (NVIDIA)
make LLAMA_CUDA=1

# Or with Apple Metal (macOS)
make LLAMA_METAL=1
```

**Download a model (GGUF format):**
```bash
# From Hugging Face, e.g.:
# https://huggingface.co/bartowski/Qwen2.5-Coder-7B-Instruct-GGUF
# Download the Q4_K_M variant

# Run the model
./main -m /path/to/model.gguf \
       -n 512 \
       -p "Write a bash function to check if a file exists"
```

**Best for:** Advanced users, custom builds, maximum performance

---

### text-generation-webui (Feature-Rich)

**Pros:**
- Web interface similar to ChatGPT
- Many extensions and plugins
- Supports multiple model formats
- Active community

**Installation:**
```bash
# Clone repository
git clone https://github.com/oobabooga/text-generation-webui
cd text-generation-webui

# Linux/macOS
./start_linux.sh   # or start_macos.sh

# Windows
start_windows.bat

# Access at http://localhost:7860
```

**Best for:** Feature-rich web UI, extensions, experimentation

---

## Privacy Comparison

### What Data is Sent Where?

#### Claude API (Cloud)

**Data sent to Anthropic:**
- Your prompts/questions
- Code you ask about
- File contents (if shared)
- Conversation history

**Anthropic's policy:**
- May use for training (unless opted out)
- Stored on their servers
- Subject to their privacy policy
- Can request deletion

**Best for:**
- Highest quality responses
- When privacy is not critical
- Quick setup needed

#### Local LLM

**Data sent:**
- Nothing (all local processing)

**Privacy:**
- Complete control
- No external network calls
- Process sensitive code safely
- No data retention by third parties

**Best for:**
- Processing sensitive code
- Working with proprietary data
- Compliance requirements
- Complete privacy control

### Hybrid Approach (Recommended)

**Use local LLM for:**
- Code review of sensitive files
- Processing proprietary algorithms
- Working with credentials/secrets (though never send these to any AI)
- Offline development
- Cost-sensitive high-volume tasks

**Use Claude API for:**
- Complex architectural decisions
- When you need the absolute best quality
- Urgent problems needing fast response
- Learning new concepts

**Example workflow:**
```bash
# Sensitive code review - use local
ollama run qwen2.5-coder:7b
>>> Review this authentication code for security issues
>>> [paste your code]

# Complex architecture question - use Claude API
claude code  # or API call
>>> How should I architect a multi-tenant Drupal system?
```

---

## Cost Analysis

### Initial Investment

| Option | Cost | What You Get |
|--------|------|--------------|
| **Try Current Machine** | $0 | See if 16GB RAM is enough |
| **RAM Upgrade** | $100-200 | 32GB RAM for better models |
| **Used Workstation** | $500-800 | 32-64GB RAM, decent CPU |
| **New Workstation** | $1500-2500 | 64GB RAM, modern CPU, GPU |
| **High-End Workstation** | $3000-5000 | 128GB RAM, RTX 4090 |

### Running Costs

**Local LLM:**
- Electricity: ~$5-20/month (depending on usage)
- No per-use costs
- One-time model downloads (free)

**Claude API:**
- Input: $3 per million tokens
- Output: $15 per million tokens
- Average: $20-200/month (depending on usage)

### ROI Calculation

**Example: Developer using AI daily**

**Claude API costs:**
- 1 million input tokens/month ≈ $3
- 200k output tokens/month ≈ $3
- **Total: ~$50-100/month**

**Local LLM:**
- Hardware: $2000 (one-time)
- Electricity: $10/month
- **ROI: 20 months**

**Break-even:** After ~20 months of moderate use

**Heavy use (5M+ tokens/month):**
- Claude API: $200-500/month
- Local LLM: Same hardware, same electricity
- **ROI: 4-10 months**

### Cost Recommendations

| Usage Level | Recommendation |
|-------------|----------------|
| **Occasional** (few times/week) | Claude API - not worth hardware investment |
| **Regular** (daily use) | Local LLM with Claude API backup |
| **Heavy** (constant use) | Dedicated local LLM workstation |
| **Team** (5+ developers) | Shared local LLM server |

---

## Alternative Platforms

### Cloud GPU Rental (Middle Ground)

**Rent powerful GPUs only when needed:**

| Provider | Cost | GPUs Available |
|----------|------|----------------|
| **Vast.ai** | $0.20-0.80/hr | RTX 3090, 4090, A5000 |
| **RunPod** | $0.34-1.00/hr | Various NVIDIA GPUs |
| **Lambda Labs** | $0.60-1.10/hr | A100, H100 |
| **AWS EC2** | $1.00-3.00/hr | Various (p3, g5 instances) |

**When to use:**
- Occasional need for powerful model (70B+)
- Testing before buying hardware
- Temporary high-volume work

**Example:** Rent RTX 4090 instance
```bash
# Connect via SSH (from Vast.ai, RunPod, etc.)
ssh -p 12345 root@gpu-instance.provider.com

# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Run large model
ollama run qwen2.5-coder:32b

# Use for a few hours, shut down
# Cost: $0.60 * 3 hours = $1.80
```

---

## Using with NWP

### Current Status (January 2026)

**F10 (Local LLM Support) is PROPOSED** but not yet implemented.

**When F10 is implemented, you'll be able to:**

```bash
# Configure AI provider
pl config set ai.provider local
pl config set ai.local.model qwen2.5-coder:7b

# Use AI features
pl llm chat                    # Interactive chat
pl llm ask "question"          # One-shot questions
pl llm code-review file.sh     # Review code
pl commit --ai-message         # AI-generated commit messages

# Switch between providers
pl config set ai.provider anthropic  # Use Claude
pl config set ai.provider local      # Use local LLM
pl config set ai.provider none       # Disable AI
```

### Manual Integration (Today)

While F10 is not implemented, you can still use local LLMs manually:

**1. Code Review:**
```bash
# Copy code to clipboard
cat lib/backup.sh | xclip -selection clipboard

# Open Ollama
ollama run qwen2.5-coder:7b

# Paste and ask for review
>>> Review this bash code for security issues and bugs
>>> [paste code]
```

**2. Commit Message Generation:**
```bash
# Get diff
git diff > /tmp/diff.txt

# Ask Ollama
ollama run qwen2.5-coder:7b
>>> Generate a commit message for these changes:
>>> [paste diff]

# Use the generated message
git commit -m "Generated message here"
```

**3. Debug Script Errors:**
```bash
# Capture error
./scripts/commands/backup.sh 2>&1 | tee /tmp/error.log

# Ask Ollama
ollama run qwen2.5-coder:7b
>>> Explain this bash error and suggest a fix:
>>> [paste error]
```

**4. API Integration (Advanced):**
```bash
# Create a helper script
cat > ~/bin/ai-ask <<'EOF'
#!/bin/bash
question="$*"
curl -s http://localhost:11434/api/generate -d "{
  \"model\": \"qwen2.5-coder:7b\",
  \"prompt\": \"$question\",
  \"stream\": false
}" | jq -r '.response'
EOF
chmod +x ~/bin/ai-ask

# Use it
ai-ask "How do I check if a bash variable is empty?"
```

---

## Troubleshooting

### Common Issues

#### Issue: "Ollama not found" after installation

**Linux:**
```bash
# Check if service is running
systemctl status ollama

# Start service
sudo systemctl start ollama

# Enable on boot
sudo systemctl enable ollama
```

**macOS:**
```bash
# Service should start automatically
# If not, run manually:
ollama serve &
```

#### Issue: Model download is very slow

**Solution:**
- Check internet connection
- Try a different mirror (Ollama uses multiple CDNs)
- Download during off-peak hours
- Use `--progress` flag for detailed progress

```bash
ollama pull qwen2.5-coder:7b --progress
```

#### Issue: "Out of memory" when running model

**Check available RAM:**
```bash
free -h
```

**Solutions:**
1. **Use smaller model:**
   ```bash
   ollama run qwen2.5-coder:3b  # Instead of 7b
   ```

2. **Close other applications:**
   ```bash
   # Free up RAM before running model
   ```

3. **Use more aggressive quantization:**
   ```bash
   # Look for Q4_0 or Q3_K_S variants
   ollama pull qwen2.5-coder:7b-q4_0
   ```

4. **Add swap space (Linux):**
   ```bash
   # Add 16GB swap (emergency only - slow)
   sudo fallocate -l 16G /swapfile
   sudo chmod 600 /swapfile
   sudo mkswap /swapfile
   sudo swapon /swapfile
   ```

#### Issue: Response is very slow

**Check what's using resources:**
```bash
# Monitor CPU/RAM during generation
htop  # or top

# Check if GPU is being used (if you have one)
nvidia-smi -l 1
```

**Solutions:**
1. **Use smaller model** (3B instead of 7B)
2. **Enable GPU acceleration** (if you have NVIDIA GPU)
3. **Close other applications**
4. **Upgrade RAM** (from 16GB to 32GB)

#### Issue: GPU not being detected

**NVIDIA GPU (Linux):**
```bash
# Check if GPU is detected
nvidia-smi

# If not, install NVIDIA drivers
sudo ubuntu-drivers autoinstall
# Or manually install from https://www.nvidia.com/drivers

# Reinstall Ollama with GPU support
# (Ollama auto-detects GPU)
```

**macOS (Apple Silicon):**
```bash
# Metal support is automatic on M1/M2/M3 Macs
# No configuration needed
```

#### Issue: Model gives poor quality responses

**Solutions:**
1. **Try a larger model:**
   ```bash
   ollama run qwen2.5-coder:14b  # Instead of 7b
   ```

2. **Adjust temperature:**
   ```bash
   ollama run qwen2.5-coder:7b
   >>> /set parameter temperature 0.3  # Lower = more focused
   ```

3. **Try a different model:**
   ```bash
   ollama run deepseek-coder-v2:16b
   ```

4. **Improve your prompt:**
   ```
   # Bad prompt:
   >>> fix this code

   # Good prompt:
   >>> Review this bash function for security issues, paying special
   >>> attention to input validation and command injection vulnerabilities:
   >>> [code here]
   ```

#### Issue: "Connection refused" when using API

**Check if Ollama is running:**
```bash
# Linux
systemctl status ollama

# macOS
ps aux | grep ollama
```

**Start Ollama if not running:**
```bash
ollama serve
```

**Check port:**
```bash
# Default port is 11434
curl http://localhost:11434/api/tags

# If using custom port:
OLLAMA_HOST=0.0.0.0:8080 ollama serve
```

---

## Advanced Topics

### Model Customization with Modelfile

Create custom models with specific behaviors:

```bash
# Create a Modelfile
cat > Modelfile <<EOF
FROM qwen2.5-coder:7b

# Set parameters
PARAMETER temperature 0.3
PARAMETER top_p 0.9

# Set system prompt
SYSTEM """
You are an expert in bash scripting and Drupal development.
Always provide secure, well-tested code examples.
Explain your reasoning clearly.
"""
EOF

# Create custom model
ollama create nwp-assistant -f Modelfile

# Use it
ollama run nwp-assistant
```

### Running Multiple Models

**Use different models for different tasks:**

```bash
# Coding tasks
alias ai-code='ollama run qwen2.5-coder:7b'

# General questions
alias ai-chat='ollama run llama3.2:8b'

# Quick answers
alias ai-quick='ollama run phi3:3.8b'
```

### API Integration Examples

**Bash script integration:**
```bash
#!/bin/bash
# ai-commit.sh - Generate commit message

diff=$(git diff --cached)

if [[ -z "$diff" ]]; then
    echo "No staged changes"
    exit 1
fi

message=$(curl -s http://localhost:11434/api/generate -d "{
    \"model\": \"qwen2.5-coder:7b\",
    \"prompt\": \"Generate a concise git commit message for these changes:\n\n$diff\",
    \"stream\": false
}" | jq -r '.response')

echo "Suggested commit message:"
echo "$message"
echo
read -p "Use this message? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    git commit -m "$message"
fi
```

**PHP integration:**
```php
<?php
function askAI(string $prompt, string $model = 'qwen2.5-coder:7b'): string {
    $ch = curl_init('http://localhost:11434/api/generate');
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_POST, true);
    curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode([
        'model' => $model,
        'prompt' => $prompt,
        'stream' => false,
    ]));

    $response = curl_exec($ch);
    curl_close($ch);

    $data = json_decode($response, true);
    return $data['response'] ?? '';
}

// Use it
$code = file_get_contents('myfile.php');
$review = askAI("Review this PHP code for security issues:\n\n$code");
echo $review;
```

### Fine-Tuning for Your Codebase

**Create a specialized model trained on your code:**

1. **Collect training data:**
   ```bash
   # Export your codebase
   find lib/ scripts/ -type f -name "*.sh" > /tmp/training-data.txt
   ```

2. **Use Ollama's fine-tuning:**
   ```bash
   # This is advanced - see Ollama docs
   # https://github.com/ollama/ollama/blob/main/docs/import.md
   ```

3. **Or use specialized tools:**
   - Axolotl: https://github.com/OpenAccess-AI-Collective/axolotl
   - LitGPT: https://github.com/Lightning-AI/litgpt

### Running as a Shared Server

**Set up Ollama as a network service:**

```bash
# On the server (e.g., 192.168.1.100)
sudo vim /etc/systemd/system/ollama.service

# Add environment variable:
Environment="OLLAMA_HOST=0.0.0.0:11434"

# Restart service
sudo systemctl daemon-reload
sudo systemctl restart ollama

# On client machines
export OLLAMA_HOST=192.168.1.100:11434
ollama run qwen2.5-coder:7b
```

**Configure in NWP (when F10 is implemented):**
```yaml
# cnwp.yml
ai:
  provider: local
  local:
    endpoint: http://192.168.1.100:11434
    model: qwen2.5-coder:7b
```

### Monitoring Performance

**Benchmark different models:**
```bash
#!/bin/bash
# benchmark.sh

models=("qwen2.5-coder:3b" "qwen2.5-coder:7b" "llama3.2:8b")
prompt="Write a bash function to check if a file exists"

for model in "${models[@]}"; do
    echo "Testing $model..."
    start=$(date +%s.%N)

    ollama run "$model" "$prompt" > /dev/null

    end=$(date +%s.%N)
    duration=$(echo "$end - $start" | bc)

    echo "  Time: ${duration}s"
done
```

---

## Recommended Learning Path

### Week 1: Getting Started
1. Install Ollama
2. Try `qwen2.5-coder:7b` for coding tasks
3. Try `llama3.2:8b` for general questions
4. Compare responses to Claude API

### Week 2: Integration
1. Create helper scripts for common tasks
2. Try API integration
3. Experiment with different models
4. Find your preferred model for different tasks

### Week 3: Optimization
1. Benchmark different models
2. Optimize prompts for better responses
3. Create custom models with Modelfile
4. Set up aliases and shortcuts

### Week 4: Advanced
1. Explore fine-tuning (optional)
2. Set up shared server (if team)
3. Integrate with your daily workflow
4. Document your learnings

---

## Resources

### Official Documentation
- Ollama: https://github.com/ollama/ollama
- Ollama Models: https://ollama.com/library
- llama.cpp: https://github.com/ggerganov/llama.cpp
- LM Studio: https://lmstudio.ai/

### Model Sources
- Hugging Face: https://huggingface.co/models
- Ollama Library: https://ollama.com/library
- TheBloke (quantized models): https://huggingface.co/TheBloke

### Community
- Ollama Discord: https://discord.gg/ollama
- Reddit r/LocalLLaMA: https://reddit.com/r/LocalLLaMA
- Ollama GitHub Discussions: https://github.com/ollama/ollama/discussions

### NWP Integration
- F10 Proposal: See `docs/ROADMAP.md` (Phase 8)
- Status: PROPOSED (not yet implemented)
- Track progress: https://github.com/yourusername/nwp/issues

---

## Conclusion

**Start here:**
1. Install Ollama: `curl -fsSL https://ollama.com/install.sh | sh`
2. Try a model: `ollama run qwen2.5-coder:7b`
3. Test it for a week
4. Decide if local LLMs work for your workflow

**Most developers find success with:**
- Local LLM (qwen2.5-coder:7b) for day-to-day coding
- Claude API for complex architectural questions
- Hybrid approach based on task sensitivity and complexity

**Questions?** Open an issue or discussion in the NWP repository.

---

**Last Updated:** January 10, 2026
**Related:** F10 proposal in `docs/ROADMAP.md`
