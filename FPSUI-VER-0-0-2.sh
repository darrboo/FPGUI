#!/bin/bash

# Enhanced 3D System Monitor - v28 (Accessibility & Console Fixes)
# Fixes:
# 1. Corrected positioning of "TOP TASKS" data to display above the platform (Accessibility).
# 2. Updated console command execution to use /bin/bash -c for robust recognition of common commands.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

print_message() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

APP_DIR="$HOME/3d-system-monitor"
mkdir -p "$APP_DIR"

print_message "Creating Panoramic 3D Monitor with Console Interface (Fixing positioning and command recognition)..."

# 1. CMakeLists (Standard)
cat > "$APP_DIR/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.10)
project(SystemMonitor3D)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(SDL2 REQUIRED)
find_package(OpenGL REQUIRED)
find_package(GLEW REQUIRED)
find_package(Freetype REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(SDL2_TTF REQUIRED SDL2_ttf)

include_directories(
    ${SDL2_INCLUDE_DIRS}
    ${SDL2_TTF_INCLUDE_DIRS}
    ${OPENGL_INCLUDE_DIRS}
    ${GLEW_INCLUDE_DIRS}
    ${FREETYPE_INCLUDE_DIRS}
)

link_directories(
    ${SDL2_TTF_LIBRARY_DIRS}
)

add_executable(system_monitor_3d main.cpp)

target_link_libraries(system_monitor_3d
    ${SDL2_LIBRARIES}
    ${SDL2_TTF_LIBRARIES}
    ${OPENGL_LIBRARIES}
    ${GLEW_LIBRARIES}
    sensors
    pthread
)
EOF

# 2. main.cpp (Fixed executeShellCommand and TOP TASKS positioning)
cat > "$APP_DIR/main.cpp" << 'CPPEOF'
#include <SDL2/SDL.h>
#include <SDL2/SDL_ttf.h>
#include <GL/glew.h>
#include <SDL2/SDL_opengl.h>
#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <glm/gtc/type_ptr.hpp>
#include <sensors/sensors.h>
#include <fstream>
#include <sstream>
#include <iostream>
#include <vector>
#include <string>
#include <cmath>
#include <thread>
#include <chrono>
#include <iomanip>
#include <map>
#include <algorithm>
#include <mutex>

// --- CONFIG AND STATE ---

struct Config {
    int screenWidth = 1280;
    int screenHeight = 720;
    float mouseSensitivity = 0.1f;
    float cameraSpeed = 8.0f;
    bool invertY = false;
    float uiScale = 1.0f; 
};

enum AppState { STATE_WORLD, STATE_OPTIONS, STATE_CONSOLE }; // ADDED STATE_CONSOLE
enum TextAlignment { ALIGN_LEFT, ALIGN_CENTER, ALIGN_RIGHT };

// --- DATA STRUCTURES ---
struct PortGroup {
    int port;
    std::string service;
    int count;
    long queueSize;
};

struct ProcessInfo {
    std::string name;
    float cpu;
    float mem;
};

struct SystemData {
    float cpuUsage = 0.0f; float cpuTemp = 0.0f;
    float memUsage = 0.0f; float memTotal = 0.0f; float memUsed = 0.0f;
    float gpuUsage = 0.0f; float gpuTemp = 0.0f;
    float netUploadSpeed = 0.0f; float netDownloadSpeed = 0.0f;
    float diskReadSpeed = 0.0f; float diskWriteSpeed = 0.0f;
    std::vector<PortGroup> activePorts; 
    std::vector<ProcessInfo> topProcesses;
};

struct Camera {
    glm::vec3 position = glm::vec3(0.0f, 2.0f, 20.0f); 
    glm::vec3 front = glm::vec3(0.0f, 0.0f, -1.0f);
    glm::vec3 up = glm::vec3(0.0f, 1.0f, 0.0f);
    glm::vec3 velocity = glm::vec3(0.0f, 0.0f, 0.0f);
    float yaw = -90.0f; float pitch = 0.0f;
    float speed = 8.0f; float sensitivity = 0.1f;
    float gravity = -15.0f; float jumpStrength = 7.0f;
    bool isOnGround = true; float groundLevel = 1.8f;
};

// --- GLOBAL VARIABLES ---
SystemData g_systemData;
std::mutex g_dataMutex; 
Camera g_camera;
Config g_config;
AppState g_appState = STATE_WORLD;
int g_selectedOption = 0;
const int NUM_OPTIONS = 8; 

bool g_keys[1024] = {false};
float g_deltaTime = 0.0f; float g_lastFrame = 0.0f;
SDL_Window* g_window = nullptr;
bool FONT_5x7[128][7][5];
GLuint g_cubeVAO = 0;
GLuint g_cubeVBO = 0;
GLuint g_cubeEBO = 0;

static unsigned long lastRx = 0, lastTx = 0;
static auto lastNetCheck = std::chrono::steady_clock::now();
static unsigned long lastDr = 0, lastDw = 0;
static auto lastDiskCheck = std::chrono::steady_clock::now();

// CONSOLE VARIABLES
std::vector<std::string> g_consoleHistory;
std::string g_currentCommand;
bool g_cursorBlink = true;


float getAspectRatio() {
    if(g_config.screenHeight == 0) return 1.0f;
    return (float)g_config.screenWidth / (float)g_config.screenHeight;
}

std::string getServiceName(int port) {
    switch(port) {
        case 20: case 21: return "FTP";
        case 22: return "SSH";
        case 53: return "DNS";
        case 80: return "HTTP";
        case 443: return "HTTPS";
        case 3306: return "MYSQL";
        case 5432: return "PGSQL";
        case 6379: return "REDIS";
        case 8080: return "WEB-ALT";
        case 27017: return "MONGO";
        case 25565: return "GAME";
        default: return std::to_string(port);
    }
}

// --- CONFIGURATION MANAGEMENT (UNCHANGED) ---
void saveConfig() {
    std::ofstream file("config.txt");
    if (file.is_open()) {
        file << "width=" << g_config.screenWidth << "\n";
        file << "height=" << g_config.screenHeight << "\n";
        file << "sensitivity=" << std::fixed << std::setprecision(2) << g_config.mouseSensitivity << "\n";
        file << "speed=" << std::fixed << std::setprecision(1) << g_config.cameraSpeed << "\n";
        file << "invertY=" << (g_config.invertY ? "true" : "false") << "\n";
        file << "uiScale=" << std::fixed << std::setprecision(2) << g_config.uiScale << "\n";
        file.close();
        g_camera.speed = g_config.cameraSpeed;
        g_camera.sensitivity = g_config.mouseSensitivity;
    }
}

void loadConfig() {
    std::ifstream file("config.txt");
    if (file.is_open()) {
        std::string line;
        while (std::getline(file, line)) {
            size_t eqPos = line.find('=');
            if (eqPos != std::string::npos) {
                std::string key = line.substr(0, eqPos);
                std::string value = line.substr(eqPos + 1);
                try {
                    if (key == "width") g_config.screenWidth = std::stoi(value);
                    else if (key == "height") g_config.screenHeight = std::stoi(value);
                    else if (key == "sensitivity") g_config.mouseSensitivity = std::stof(value);
                    else if (key == "speed") g_config.cameraSpeed = std::stof(value);
                    else if (key == "invertY") g_config.invertY = (value == "1" || value == "true");
                    else if (key == "uiScale") g_config.uiScale = std::stof(value);
                } catch (...) { }
            }
        }
        file.close();
        g_config.uiScale = std::clamp(g_config.uiScale, 0.5f, 1.5f);
        g_camera.speed = g_config.cameraSpeed;
        g_camera.sensitivity = g_config.mouseSensitivity;
    } else {
        saveConfig();
    }
}

// --- CONSOLE COMMAND LOGIC ---

std::vector<std::string> executeShellCommand(const std::string& command) {
    std::vector<std::string> output;
    if (command.empty()) return output;

    // FIX (v28): Execute via /bin/bash -c for robust PATH and command recognition, 
    // resolving issues where popen's default shell/environment is too limited.
    // The user's command is safely escaped and wrapped in single quotes inside the bash call.
    std::string escaped_command = command;
    size_t pos = 0;
    // Replace all single quotes in command with escaped ones: '\''
    while ((pos = escaped_command.find('\'', pos)) != std::string::npos) {
         escaped_command.replace(pos, 1, "'\\''"); 
         pos += 4;
    }
    
    // Construct the full command: /bin/bash -c 'user_command 2>&1'
    std::string full_command = "/bin/bash -c '" + escaped_command + " 2>&1'";
    
    FILE* pipe = popen(full_command.c_str(), "r");
    if (!pipe) {
        output.push_back("Error: Failed to execute command.");
        return output;
    }

    char buffer[128];
    while (fgets(buffer, sizeof(buffer), pipe) != nullptr) {
        std::string line = buffer;
        // Trim newline
        if (!line.empty() && line.back() == '\n') {
            line.pop_back();
        }
        // Truncate long lines to fit console width (e.g., 60 chars)
        if (line.length() > 60) {
            line = line.substr(0, 57) + "...";
        }
        output.push_back(line);
    }
    pclose(pipe);
    return output;
}

// --- DATA GATHERING (UNCHANGED FROM V25) ---

void updateProcessList() {
    FILE* pipe = popen("ps -eo comm,%cpu,%mem --sort=-%cpu --no-headers | head -n 10", "r");
    if (!pipe) return;

    std::vector<ProcessInfo> procs;
    char buffer[128];
    while (fgets(buffer, sizeof(buffer), pipe)) {
        std::string line(buffer);
        std::stringstream ss(line);
        std::string name;
        float cpu, mem;
        ss >> name >> cpu >> mem;
        if (name.length() > 12) name = name.substr(0, 12);
        procs.push_back({name, cpu, mem});
    }
    pclose(pipe);

    std::lock_guard<std::mutex> lock(g_dataMutex);
    g_systemData.topProcesses = procs;
}

void updateActivePorts() {
    std::map<int, std::pair<int, long>> portStats;
    
    auto parseFile = [&](const char* path) {
        std::ifstream file(path);
        if (!file.is_open()) return;
        std::string line; std::getline(file, line); 
        while (std::getline(file, line)) {
            std::stringstream ss(line);
            std::string id, localAddr, remoteAddr, state, queues;
            ss >> id >> localAddr >> remoteAddr >> state >> queues;
            if (state == "01") { 
                size_t colonPos = remoteAddr.find(':');
                if (colonPos != std::string::npos) {
                    std::string portHex = remoteAddr.substr(colonPos + 1);
                    long activeBytes = 0;
                    size_t qColon = queues.find(':');
                    if (qColon != std::string::npos) {
                        try { activeBytes = std::stol(queues.substr(0, qColon),nullptr,16) + std::stol(queues.substr(qColon+1),nullptr,16); } catch(...) {}
                    }
                    try {
                        int port = std::stoi(portHex, nullptr, 16);
                        if (port != 0) { portStats[port].first++; portStats[port].second += activeBytes; }
                    } catch (...) {}
                }
            }
        }
    };
    parseFile("/proc/net/tcp"); parseFile("/proc/net/tcp6");

    std::vector<PortGroup> tempPorts;
    for (auto const& [port, stats] : portStats) {
        tempPorts.push_back({port, getServiceName(port), stats.first, stats.second});
    }
    std::sort(tempPorts.begin(), tempPorts.end(), [](const PortGroup& a, const PortGroup& b) {
        if (a.queueSize != b.queueSize) return a.queueSize > b.queueSize;
        return a.count > b.count;
    });
    if (tempPorts.size() > 8) tempPorts.resize(8);

    std::lock_guard<std::mutex> lock(g_dataMutex);
    g_systemData.activePorts = tempPorts;
}

void updateNetworkStats() {
    std::ifstream netFile("/proc/net/dev");
    if (!netFile.is_open()) return;
    std::string line;
    unsigned long rxBytes = 0, txBytes = 0;
    while (std::getline(netFile, line)) {
        if (line.find(':') != std::string::npos && line.find("lo:") == std::string::npos) {
            std::istringstream ss(line.substr(line.find(':') + 1));
            unsigned long rx, tx;
            ss >> rx;
            for (int i = 0; i < 7; i++) ss >> tx;
            ss >> tx;
            rxBytes += rx; txBytes += tx;
        }
    }
    netFile.close();
    auto now = std::chrono::steady_clock::now();
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - lastNetCheck).count() / 1000.0;
    if (lastRx > 0 && elapsed > 0) {
        std::lock_guard<std::mutex> lock(g_dataMutex);
        g_systemData.netDownloadSpeed = ((rxBytes - lastRx) / 1024.0) / elapsed;
        g_systemData.netUploadSpeed = ((txBytes - lastTx) / 1024.0) / elapsed;
    }
    lastRx = rxBytes; lastTx = txBytes; lastNetCheck = now;
}

void updateGPUStats() {
    float usage = 0, temp = 0;
    FILE* pipe = popen("nvidia-smi --query-gpu=utilization.gpu,temperature.gpu --format=csv,noheader,nounits 2>/dev/null", "r");
    if (pipe) {
        char buffer[128];
        if (fgets(buffer, sizeof(buffer), pipe)) { sscanf(buffer, "%f, %f", &usage, &temp); }
        pclose(pipe);
    } else {
        std::ifstream amd("/sys/class/drm/card0/device/gpu_busy_percent");
        if(amd.is_open()) amd >> usage;
        sensors_init(NULL);
        const sensors_chip_name *chip; int chip_nr = 0;
        while ((chip = sensors_get_detected_chips(NULL, &chip_nr)) != NULL) {
            if (strstr(chip->prefix, "amdgpu") || strstr(chip->prefix, "radeon")) {
                const sensors_feature *f; int f_nr = 0;
                    while ((f = sensors_get_features(chip, &f_nr)) != NULL) {
                    if (f->type == SENSORS_FEATURE_TEMP) {
                        const sensors_subfeature *s = sensors_get_subfeature(chip, f, SENSORS_SUBFEATURE_TEMP_INPUT);
                        if (s) { double v; if (sensors_get_value(chip, s->number, &v) == 0) { temp = v; break; } }
                    }
                }
            }
            if (temp > 0) break;
        }
        sensors_cleanup();
    }
    std::lock_guard<std::mutex> lock(g_dataMutex);
    g_systemData.gpuUsage = usage; g_systemData.gpuTemp = temp;
}

void updateDiskIOStats() {
    std::ifstream diskFile("/proc/diskstats");
    if (!diskFile.is_open()) return;
    std::string line;
    unsigned long rs = 0, ws = 0;
    while (std::getline(diskFile, line)) {
        std::istringstream ss(line);
        std::string dev; unsigned long r, rm, rsec, rms, w, wm, wsec; int m,n; ss >> m >> n >> dev;
        if (dev.find("loop") == std::string::npos && dev.length() <= 7 && dev.find("sr") == std::string::npos) {
            ss >> r >> rm >> rsec >> rms >> w >> wm >> wsec; rs += rsec; ws += wsec;
        }
    }
    auto now = std::chrono::steady_clock::now();
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - lastDiskCheck).count() / 1000.0;
    if (lastDr > 0 && elapsed > 0) {
        std::lock_guard<std::mutex> lock(g_dataMutex);
        g_systemData.diskReadSpeed = ((rs - lastDr) * 512 / 1024.0) / elapsed;
        g_systemData.diskWriteSpeed = ((ws - lastDw) * 512 / 1024.0) / elapsed;
    }
    lastDr = rs; lastDw = ws; lastDiskCheck = now;
}

void updateSystemData() {
    float cUsage = 0;
    std::ifstream statFile("/proc/stat");
    if (statFile.is_open()) {
        std::string line; std::getline(statFile, line);
        std::istringstream ss(line);
        std::string cpu; long user, nice, system, idle;
        ss >> cpu >> user >> nice >> system >> idle;
        static long pIdle = 0, pTotal = 0;
        long total = user + nice + system + idle;
        long totald = total - pTotal; long idled = idle - pIdle;
        cUsage = totald > 0 ? (100.0f * (totald - idled) / totald) : 0.0f;
        pIdle = idle; pTotal = total;
    }
    
    float mTotal = 0, mUsed = 0, mUsage = 0;
    std::ifstream memFile("/proc/meminfo");
    if (memFile.is_open()) {
        std::string line; long memTotal = 0, memAvailable = 0;
        while (std::getline(memFile, line)) {
            if (line.find("MemTotal:") != std::string::npos) sscanf(line.c_str(), "MemTotal: %ld", &memTotal);
            else if (line.find("MemAvailable:") != std::string::npos) sscanf(line.c_str(), "MemAvailable: %ld", &memAvailable);
        }
        if (memTotal > 0) {
            mTotal = memTotal / 1024.0f / 1024.0f;
            mUsed = (memTotal - memAvailable) / 1024.0f / 1024.0f;
            mUsage = ((memTotal - memAvailable) / (float)memTotal) * 100.0f;
        }
    }

    float cTemp = 0;
    sensors_init(NULL);
    const sensors_chip_name *chip; int chip_nr = 0;
    while ((chip = sensors_get_detected_chips(NULL, &chip_nr)) != NULL) {
        const sensors_feature *f; int f_nr = 0;
        while ((f = sensors_get_features(chip, &f_nr)) != NULL) {
            if (f->type == SENSORS_FEATURE_TEMP) {
                if (strstr(chip->prefix, "coretemp") || strstr(chip->prefix, "k10temp")) {
                    const sensors_subfeature *s = sensors_get_subfeature(chip, f, SENSORS_SUBFEATURE_TEMP_INPUT);
                    if (s) { double v; if (sensors_get_value(chip, s->number, &v) == 0) { cTemp = v; break; } }
                }
            }
        }
        if (cTemp > 0) break;
    }
    sensors_cleanup();
    
    {
        std::lock_guard<std::mutex> lock(g_dataMutex);
        g_systemData.cpuUsage = cUsage; g_systemData.cpuTemp = cTemp;
        g_systemData.memTotal = mTotal; g_systemData.memUsed = mUsed; g_systemData.memUsage = mUsage;
    }

    updateGPUStats(); updateNetworkStats(); updateDiskIOStats(); updateActivePorts(); updateProcessList();
}

void sysThread() { while(true) { updateSystemData(); std::this_thread::sleep_for(std::chrono::milliseconds(1000)); } }

// --- FONT ENGINE (UNCHANGED) ---
void setRow(int c, int r, std::string p) { for(int i=0; i<5; i++) FONT_5x7[c][r][i] = (p[i] == '1'); }
void initFont() {
    for(int c=0;c<128;c++) for(int r=0;r<7;r++) for(int k=0;k<5;k++) FONT_5x7[c][r][k] = false;
    setRow('0',0,"01110"); setRow('0',1,"10001"); setRow('0',2,"10011"); setRow('0',3,"10101"); setRow('0',4,"11001"); setRow('0',5,"10001"); setRow('0',6,"01110");
    setRow('1',0,"00100"); setRow('1',1,"01100"); setRow('1',2,"00100"); setRow('1',3,"00100"); setRow('1',4,"00100"); setRow('1',5,"00100"); setRow('1',6,"01110");
    setRow('2',0,"01110"); setRow('2',1,"10001"); setRow('2',2,"00001"); setRow('2',3,"00110"); setRow('2',4,"01000"); setRow('2',5,"10000"); setRow('2',6,"11111");
    setRow('3',0,"01110"); setRow('3',1,"10001"); setRow('3',2,"00001"); setRow('3',3,"00110"); setRow('3',4,"00001"); setRow('3',5,"10001"); setRow('3',6,"01110");
    setRow('4',0,"00010"); setRow('4',1,"00110"); setRow('4',2,"01010"); setRow('4',3,"10010"); setRow('4',4,"11111"); setRow('4',5,"00010"); setRow('4',6,"00010");
    setRow('5',0,"11111"); setRow('5',1,"10000"); setRow('5',2,"11110"); setRow('5',3,"00001"); setRow('5',4,"00001"); setRow('5',5,"10001"); setRow('5',6,"01110");
    setRow('6',0,"00110"); setRow('6',1,"01000"); setRow('6',2,"10000"); setRow('6',3,"11110"); setRow('6',4,"10001"); setRow('6',5,"10001"); setRow('6',6,"01110");
    setRow('7',0,"11111"); setRow('7',1,"00001"); setRow('7',2,"00010"); setRow('7',3,"00100"); setRow('7',4,"01000"); setRow('7',5,"01000"); setRow('7',6,"01000");
    setRow('8',0,"01110"); setRow('8',1,"10001"); setRow('8',2,"10001"); setRow('8',3,"01110"); setRow('8',4,"10001"); setRow('8',5,"10001"); setRow('8',6,"01110");
    setRow('9',0,"01110"); setRow('9',1,"10001"); setRow('9',2,"10001"); setRow('9',3,"01111"); setRow('9',4,"00001"); setRow('9',5,"00010"); setRow('9',6,"01100");
    setRow('A',0,"01110"); setRow('A',1,"10001"); setRow('A',2,"10001"); setRow('A',3,"11111"); setRow('A',4,"10001"); setRow('A',5,"10001"); setRow('A',6,"10001");
    setRow('B',0,"11110"); setRow('B',1,"10001"); setRow('B',2,"10001"); setRow('B',3,"11110"); setRow('B',4,"10001"); setRow('B',5,"10001"); setRow('B',6,"11110");
    setRow('C',0,"01110"); setRow('C',1,"10001"); setRow('C',2,"10000"); setRow('C',3,"10000"); setRow('C',4,"10000"); setRow('C',5,"10001"); setRow('C',6,"01110");
    setRow('D',0,"11110"); setRow('D',1,"10001"); setRow('D',2,"10001"); setRow('D',3,"10001"); setRow('D',4,"10001"); setRow('D',5,"10001"); setRow('D',6,"11110");
    setRow('E',0,"11111"); setRow('E',1,"10000"); setRow('E',2,"10000"); setRow('E',3,"11110"); setRow('E',4,"10000"); setRow('E',5,"10000"); setRow('E',6,"11111");
    setRow('F',0,"11111"); setRow('F',1,"10000"); setRow('F',1,"10000"); setRow('F',2,"10000"); setRow('F',3,"11110"); setRow('F',4,"10000"); setRow('F',5,"10000"); setRow('F',6,"10000");
    setRow('G',0,"01110"); setRow('G',1,"10001"); setRow('G',2,"10000"); setRow('G',3,"10011"); setRow('G',4,"10001"); setRow('G',5,"10001"); setRow('G',6,"01110");
    setRow('H',0,"10001"); setRow('H',1,"10001"); setRow('H',2,"10001"); setRow('H',3,"11111"); setRow('H',4,"10001"); setRow('H',5,"10001"); setRow('H',6,"10001");
    setRow('I',0,"01110"); setRow('I',1,"00100"); setRow('I',2,"00100"); setRow('I',3,"00100"); setRow('I',4,"00100"); setRow('I',5,"00100"); setRow('I',6,"01110");
    setRow('J',0,"00001"); setRow('J',1,"00001"); setRow('J',2,"00001"); setRow('J',3,"00001"); setRow('J',4,"10001"); setRow('J',5,"10001"); setRow('J',6,"01110");
    setRow('K',0,"10001"); setRow('K',1,"10010"); setRow('K',2,"10100"); setRow('K',3,"11000"); setRow('K',4,"10100"); setRow('K',5,"10010"); setRow('K',6,"10001");
    setRow('L',0,"10000"); setRow('L',1,"10000"); setRow('L',2,"10000"); setRow('L',3,"10000"); setRow('L',4,"10000"); setRow('L',5,"10000"); setRow('L',6,"11111");
    setRow('M',0,"10001"); setRow('M',1,"11011"); setRow('M',2,"10101"); setRow('M',3,"10001"); setRow('M',4,"10001"); setRow('M',5,"10001"); setRow('M',6,"10001");
    setRow('N',0,"10001"); setRow('N',1,"11001"); setRow('N',2,"10101"); setRow('N',3,"10011"); setRow('N',4,"10001"); setRow('N',5,"10001"); setRow('N',6,"10001");
    setRow('O',0,"01110"); setRow('O',1,"10001"); setRow('O',2,"10001"); setRow('O',3,"10001"); setRow('O',4,"10001"); setRow('O',5,"10001"); setRow('O',6,"01110");
    setRow('P',0,"11110"); setRow('P',1,"10001"); setRow('P',2,"10001"); setRow('P',3,"11110"); setRow('P',4,"10000"); setRow('P',5,"10000"); setRow('P',6,"10000");
    setRow('Q',0,"01110"); setRow('Q',1,"10001"); setRow('Q',2,"10001"); setRow('Q',3,"10001"); setRow('Q',4,"10101"); setRow('Q',5,"10010"); setRow('Q',6,"01101");
    setRow('R',0,"11110"); setRow('R',1,"10001"); setRow('R',2,"10001"); setRow('R',3,"11110"); setRow('R',4,"10100"); setRow('R',5,"10010"); setRow('R',6,"10001");
    setRow('S',0,"01111"); setRow('S',1,"10000"); setRow('S',2,"10000"); setRow('S',3,"01110"); setRow('S',4,"00001"); setRow('S',5,"00001"); setRow('S',6,"11110");
    setRow('T',0,"11111"); setRow('T',1,"00100"); setRow('T',2,"00100"); setRow('T',3,"00100"); setRow('T',4,"00100"); setRow('T',5,"00100"); setRow('T',6,"00100");
    setRow('U',0,"10001"); setRow('U',1,"10001"); setRow('U',2,"10001"); setRow('U',3,"10001"); setRow('U',4,"10001"); setRow('U',5,"10001"); setRow('U',6,"01110");
    setRow('V',0,"10001"); setRow('V',1,"10001"); setRow('V',2,"10001"); setRow('V',3,"10001"); setRow('V',4,"10001"); setRow('V',5,"01010"); setRow('V',6,"00100");
    setRow('W',0,"10001"); setRow('W',1,"10001"); setRow('W',2,"10001"); setRow('W',3,"10101"); setRow('W',4,"10101"); setRow('W',5,"11011"); setRow('W',6,"10001");
    setRow('X',0,"10001"); setRow('X',1,"10001"); setRow('X',2,"01010"); setRow('X',3,"00100"); setRow('X',4,"01010"); setRow('X',5,"10001"); setRow('X',6,"10001");
    setRow('Y',0,"10001"); setRow('Y',1,"10001"); setRow('Y',2,"01010"); setRow('Y',3,"00100"); setRow('Y',4,"00100"); setRow('Y',5,"00100"); setRow('Y',6,"00100");
    setRow('Z',0,"11111"); setRow('Z',1,"00001"); setRow('Z',2,"00010"); setRow('Z',3,"00100"); setRow('Z',4,"01000"); setRow('Z',5,"10000"); setRow('Z',6,"11111");
    setRow(':',0,"00000"); setRow(':',1,"00100"); setRow(':',2,"00000"); setRow(':',3,"00000"); setRow(':',4,"00100"); setRow(':',5,"00000"); setRow(':',6,"00000");
    setRow('/',0,"00001"); setRow('/',1,"00001"); setRow('/',2,"00010"); setRow('/',3,"00100"); setRow('/',4,"01000"); setRow('/',5,"10000"); setRow('/',6,"10000");
    setRow('%',0,"11001"); setRow('%',1,"11010"); setRow('%',2,"00100"); setRow('%',3,"01000"); setRow('%',4,"10001"); setRow('%',5,"10001"); setRow('%',6,"00000");
    setRow(' ',0,"00000"); setRow(' ',1,"00000"); setRow(' ',2,"00000"); setRow(' ',3,"00000"); setRow(' ',4,"00000"); setRow(' ',5,"00000"); setRow(' ',6,"00000");
    setRow('.',0,"00000"); setRow('.',1,"00000"); setRow('.',2,"00000"); setRow('.',3,"00000"); setRow('.',4,"00000"); setRow('.',5,"00100"); setRow('.',6,"00000");
    setRow('-',0,"00000"); setRow('-',1,"00000"); setRow('-',2,"00000"); setRow('-',3,"11111"); setRow('-',4,"00000"); setRow('-',5,"00000"); setRow('-',6,"00000");
    setRow('<',0,"00011"); setRow('<',1,"00100"); setRow('<',2,"01000"); setRow('<',3,"10000"); setRow('<',4,"01000"); setRow('<',5,"00100"); setRow('<',6,"00011");
    setRow('>',0,"11000"); setRow('>',1,"00100"); setRow('>',2,"00010"); setRow('>',3,"00001"); setRow('>',4,"00010"); setRow('>',5,"00100"); setRow('>',6,"11000");
    setRow('[',0,"11100"); setRow('[',1,"10000"); setRow('[',2,"10000"); setRow('[',3,"10000"); setRow('[',4,"10000"); setRow('[',5,"10000"); setRow('[',6,"11100");
    setRow(']',0,"00111"); setRow(']',1,"00001"); setRow(']',2,"00001"); setRow(']',3,"00001"); setRow(']',4,"00001"); setRow(']',5,"00001"); setRow(']',6,"00111");
    setRow('`',0,"00100"); setRow('`',1,"01000"); setRow('`',2,"00000"); setRow('`',3,"00000"); setRow('`',4,"00000"); setRow('`',5,"00000"); setRow('`',6,"00000");
}

void drawBitmapChar(std::vector<float>& verts, char c, float x, float y, float sizeX, float sizeY, glm::vec3 col) {
    c = toupper(c);
    if(c < 0 || c >= 128) c = '?';
    for(int r=0;r<7;r++) {
        for(int k=0;k<5;k++) {
            if(FONT_5x7[(int)c][r][k]) {
                float px=x+k*sizeX; float py=y-r*sizeY;
                verts.insert(verts.end(), {
                    px,py,0, col.r,col.g,col.b, px+sizeX,py,0, col.r,col.g,col.b, px+sizeX,py+sizeY,0, col.r,col.g,col.b,
                    px,py,0, col.r,col.g,col.b, px+sizeX,py+sizeY,0, col.r,col.g,col.b, px,py+sizeY,0, col.r,col.g,col.b
                });
            }
        }
    }
}

void drawTextNDC(GLuint prog, std::string text, glm::vec3 pos, glm::vec3 color, float scale, TextAlignment align = ALIGN_CENTER) {
    std::vector<float> verts;
    float aspect = getAspectRatio();
    float sizeY = scale * 0.008f;
    float sizeX = sizeY / aspect; 
    float width = 6 * sizeX;
    float textWidth = text.length() * width;
    float startX;

    if (align == ALIGN_CENTER) startX = pos.x - textWidth / 2.0f;
    else if (align == ALIGN_RIGHT) startX = pos.x - textWidth;
    else startX = pos.x;

    for(char c : text) { drawBitmapChar(verts, c, startX, pos.y, sizeX, sizeY, color); startX += width; }
    if(verts.empty()) return;

    GLuint VAO, VBO; glGenVertexArrays(1,&VAO); glGenBuffers(1,&VBO);
    glBindVertexArray(VAO); glBindBuffer(GL_ARRAY_BUFFER, VBO);
    glBufferData(GL_ARRAY_BUFFER, verts.size()*sizeof(float), verts.data(), GL_STATIC_DRAW);
    glVertexAttribPointer(0,3,GL_FLOAT,GL_FALSE,6*sizeof(float),0); glEnableVertexAttribArray(0);
    glVertexAttribPointer(1,3,GL_FLOAT,GL_FALSE,6*sizeof(float),(void*)(3*sizeof(float))); glEnableVertexAttribArray(1);
    
    glm::mat4 model = glm::translate(glm::mat4(1.0f), glm::vec3(0.0f)); 
    glUniformMatrix4fv(glGetUniformLocation(prog,"model"),1,GL_FALSE,glm::value_ptr(model));
    glUniform1i(glGetUniformLocation(prog,"isHUD"), 1); 
    glUniform3f(glGetUniformLocation(prog, "uniColor"), color.r, color.g, color.b);
    glUniform1f(glGetUniformLocation(prog, "alpha"), 1.0f);

    glDrawArrays(GL_TRIANGLES, 0, verts.size()/6);
    glDeleteVertexArrays(1,&VAO); glDeleteBuffers(1,&VBO);
}

void drawRectNDC(GLuint prog, glm::vec3 pos, glm::vec2 size, glm::vec3 color, float alpha) {
    float aspect = getAspectRatio();
    float w = size.x / aspect; 
    float h = size.y;
    float hw = w / 2.0f;
    float hh = h / 2.0f;
    float x1 = pos.x - hw; float x2 = pos.x + hw;
    float y1 = pos.y - hh; float y2 = pos.y + hh;
    float verts[] = {
        x1, y1, 0.0f, 0.0f, 0.0f, 0.0f, x2, y1, 0.0f, 0.0f, 0.0f, 0.0f, x2, y2, 0.0f, 0.0f, 0.0f, 0.0f,
        x1, y1, 0.0f, 0.0f, 0.0f, 0.0f, x2, y2, 0.0f, 0.0f, 0.0f, 0.0f, x1, y2, 0.0f, 0.0f, 0.0f, 0.0f
    };
    GLuint VAO, VBO; glGenVertexArrays(1,&VAO); glGenBuffers(1,&VBO);
    glBindVertexArray(VAO); glBindBuffer(GL_ARRAY_BUFFER, VBO);
    glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STATIC_DRAW);
    glVertexAttribPointer(0,3,GL_FLOAT,GL_FALSE,6*sizeof(float),0); glEnableVertexAttribArray(0);
    glVertexAttribPointer(1,3,GL_FLOAT,GL_FALSE,6*sizeof(float),(void*)(3*sizeof(float))); glEnableVertexAttribArray(1);

    glm::mat4 model = glm::mat4(1.0f); 
    glUniformMatrix4fv(glGetUniformLocation(prog,"model"),1,GL_FALSE,glm::value_ptr(model));
    glUniform1i(glGetUniformLocation(prog,"isHUD"), 1);
    glUniform3f(glGetUniformLocation(prog, "uniColor"), color.r, color.g, color.b);
    glUniform1f(glGetUniformLocation(prog, "alpha"), alpha);
    
    glEnable(GL_BLEND); glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glDrawArrays(GL_TRIANGLES, 0, 6);
    glDisable(GL_BLEND);
    glDeleteVertexArrays(1,&VAO); glDeleteBuffers(1,&VBO);
}

void drawTextWorld(GLuint prog, std::string text, glm::vec3 pos, glm::vec3 color, float scale = 8.0f, TextAlignment align = ALIGN_CENTER) {
    std::vector<float> verts;
    float size = scale * 0.005f; 
    float width = 6 * size;
    float textWidth = text.length() * width;
    float startX;

    if (align == ALIGN_CENTER) startX = -textWidth / 2.0f;
    else if (align == ALIGN_RIGHT) startX = -textWidth;
    else startX = 0.0f; 

    for(char c : text) { drawBitmapChar(verts, c, startX, 0.0f, size, size, color); startX += width; }
    if(verts.empty()) return;

    // FIX: Corrected VAAO to VAO (Fix applied in v27)
    GLuint VAO, VBO; glGenVertexArrays(1,&VAO); glGenBuffers(1,&VBO);
    glBindVertexArray(VAO); glBindBuffer(GL_ARRAY_BUFFER, VBO);
    glBufferData(GL_ARRAY_BUFFER, verts.size()*sizeof(float), verts.data(), GL_STATIC_DRAW);
    glVertexAttribPointer(0,3,GL_FLOAT,GL_FALSE,6*sizeof(float),0); glEnableVertexAttribArray(0);
    glVertexAttribPointer(1,3,GL_FLOAT,GL_FALSE,6*sizeof(float),(void*)(3*sizeof(float))); glEnableVertexAttribArray(1);
    
    glm::mat4 model(1.0f);
    model = glm::translate(model, pos); 
    glm::mat4 V_rot_only = glm::mat4(glm::mat3(glm::lookAt(g_camera.position, g_camera.position + g_camera.front, g_camera.up)));
    model *= glm::transpose(V_rot_only);
    
    glUniformMatrix4fv(glGetUniformLocation(prog,"model"),1,GL_FALSE,glm::value_ptr(model));
    glUniform1i(glGetUniformLocation(prog,"isHUD"), 0); 
    glUniform3f(glGetUniformLocation(prog, "uniColor"), color.r, color.g, color.b); 
    glUniform1f(glGetUniformLocation(prog, "alpha"), 1.0f);

    glDrawArrays(GL_TRIANGLES, 0, verts.size()/6);
    glDeleteVertexArrays(1,&VAO); glDeleteBuffers(1,&VBO);
}

// --- EFFICIENT 3D DRAWING (UNCHANGED) ---

void initCubeBuffers() {
    float v[] = { -0.5f,-0.5f,-0.5f, 1,1,1, 0.5f,-0.5f,-0.5f, 1,1,1, 0.5f,0.5f,-0.5f, 1,1,1,
                  -0.5f,0.5f,-0.5f, 1,1,1, -0.5f,-0.5f,0.5f, 1,1,1, 0.5f,-0.5f,0.5f, 1,1,1,
                   0.5f,0.5f,0.5f, 1,1,1, -0.5f,0.5f,0.5f, 1,1,1 };
    unsigned int i[] = {0,1,2,2,3,0, 4,5,6,6,7,4, 0,1,5,5,4,0, 2,3,7,7,6,2, 0,3,7,7,4,0, 1,2,6,6,5,1};
    glGenVertexArrays(1,&g_cubeVAO); glGenBuffers(1,&g_cubeVBO); glGenBuffers(1,&g_cubeEBO);
    glBindVertexArray(g_cubeVAO); 
    glBindBuffer(GL_ARRAY_BUFFER,g_cubeVBO); glBufferData(GL_ARRAY_BUFFER,sizeof(v),v,GL_STATIC_DRAW);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,g_cubeEBO); glBufferData(GL_ELEMENT_ARRAY_BUFFER,sizeof(i),i,GL_STATIC_DRAW);
    glVertexAttribPointer(0,3,GL_FLOAT,GL_FALSE,6*sizeof(float),0); glEnableVertexAttribArray(0);
    glVertexAttribPointer(1,3,GL_FLOAT,GL_FALSE,6*sizeof(float),(void*)(3*sizeof(float))); glEnableVertexAttribArray(1);
    glBindVertexArray(0); 
}

void drawCube(GLuint prog, glm::vec3 pos, glm::vec3 sz, glm::vec3 col) {
    if(g_cubeVAO == 0) return;
    glm::mat4 m(1.0f); 
    m=glm::translate(m,pos); 
    m=glm::scale(m,sz);
    glUniformMatrix4fv(glGetUniformLocation(prog,"model"),1,GL_FALSE,glm::value_ptr(m));
    glUniform1i(glGetUniformLocation(prog,"isHUD"),0);
    glUniform3f(glGetUniformLocation(prog, "uniColor"), col.r, col.g, col.b);
    glUniform1f(glGetUniformLocation(prog, "alpha"), 1.0f);
    glBindVertexArray(g_cubeVAO);
    glDrawElements(GL_TRIANGLES,36,GL_UNSIGNED_INT,0);
    glBindVertexArray(0);
}

void drawSystemTower(GLuint prog, float xPos, float value, float temp, glm::vec3 baseColor, float time) {
    float height = 0.5f + (value / 100.0f) * 5.0f;
    float baseSize = 2.0f;
    float pulse = (sin(time*2)+1)/2 * 0.2f + 0.8f;
    drawCube(prog, glm::vec3(xPos, 0.5f, 0), glm::vec3(baseSize, 1.0f, baseSize), glm::vec3(0.05f));
    drawCube(prog, glm::vec3(xPos, 1.0f + height / 2.0f, 0), glm::vec3(baseSize * 0.8f, height, baseSize * 0.8f), baseColor * pulse);
    drawCube(prog, glm::vec3(xPos, height + 1.0f, 0), glm::vec3(baseSize, 0.1f, baseSize), baseColor * 0.5f);
    float normTemp = glm::clamp((temp - 30.0f) / (70.0f), 0.0f, 1.0f);
    drawCube(prog, glm::vec3(xPos, 1.5f, -1.5f), glm::vec3(0.5f, 0.5f, 0.5f), glm::mix(glm::vec3(0.0f, 0.8f, 0.0f), glm::vec3(1.0f, 0.0f, 0.0f), normTemp));
}

void drawFloor(GLuint prog) {
    std::vector<float> v;
    for(float i=-50; i<=50; i+=2) {
        v.insert(v.end(), {i,0,-50, 0.2f,0.2f,0.2f, i,0,50, 0.2f,0.2f,0.2f, -50,0,i, 0.2f,0.2f,0.2f, 50,0,i, 0.2f,0.2f,0.2f});
    }
    GLuint VAO,VBO; glGenVertexArrays(1,&VAO); glGenBuffers(1,&VBO);
    glBindVertexArray(VAO); glBindBuffer(GL_ARRAY_BUFFER,VBO);
    glBufferData(GL_ARRAY_BUFFER, v.size()*sizeof(float), v.data(), GL_STATIC_DRAW);
    glVertexAttribPointer(0,3,GL_FLOAT,GL_FALSE,6*sizeof(float),0); glEnableVertexAttribArray(0);
    glVertexAttribPointer(1,3,GL_FLOAT,GL_FALSE,6*sizeof(float),(void*)(3*sizeof(float))); glEnableVertexAttribArray(1);
    glm::mat4 m(1.0f); 
    glUniformMatrix4fv(glGetUniformLocation(prog,"model"),1,GL_FALSE,glm::value_ptr(m));
    glUniform1i(glGetUniformLocation(prog,"isHUD"),0);
    glUniform3f(glGetUniformLocation(prog, "uniColor"), 1.0f, 1.0f, 1.0f); 
    glUniform1f(glGetUniformLocation(prog, "alpha"), 1.0f);
    glDrawArrays(GL_LINES, 0, v.size()/6);
    glDeleteVertexArrays(1,&VAO); glDeleteBuffers(1,&VBO);
}

void processInput() {
    float v = g_config.cameraSpeed * g_deltaTime;
    glm::vec3 f = glm::normalize(glm::vec3(g_camera.front.x, 0, g_camera.front.z));
    if(g_keys[SDL_SCANCODE_W]) g_camera.position += f * v;
    if(g_keys[SDL_SCANCODE_S]) g_camera.position -= f * v;
    if(g_keys[SDL_SCANCODE_A]) g_camera.position -= glm::normalize(glm::cross(f, g_camera.up)) * v;
    if(g_keys[SDL_SCANCODE_D]) g_camera.position += glm::normalize(glm::cross(f, g_camera.up)) * v;
    if(g_keys[SDL_SCANCODE_SPACE] && g_camera.isOnGround) { g_camera.velocity.y = g_camera.jumpStrength; g_camera.isOnGround = false; }
    if(!g_keys[SDL_SCANCODE_LSHIFT]) {
        g_camera.velocity.y += g_camera.gravity * g_deltaTime; g_camera.position.y += g_camera.velocity.y * g_deltaTime;
        if(g_camera.position.y <= g_camera.groundLevel) { g_camera.position.y = g_camera.groundLevel; g_camera.velocity.y = 0; g_camera.isOnGround = true; }
    } else { if(g_keys[SDL_SCANCODE_SPACE]) g_camera.position.y += v; g_camera.velocity.y = 0; }
}

// --- OPTIONS MENU (UNCHANGED) ---

void drawProgressBar(GLuint prog, float x, float y, float width, float height, float val, float maxVal) {
    float ratio = val / maxVal;
    if(ratio > 1.0f) ratio = 1.0f; if(ratio < 0.0f) ratio = 0.0f;
    drawRectNDC(prog, glm::vec3(x, y, 0), glm::vec2(width, height), glm::vec3(0.2f, 0.2f, 0.2f), 1.0f);
    if (ratio > 0.01f) {
        float barW = width * ratio;
        float barX = (x - width/2.0f) + (barW/2.0f);
        drawRectNDC(prog, glm::vec3(barX, y, 0), glm::vec2(barW, height), glm::vec3(0.0f, 0.8f, 0.8f), 1.0f);
    }
}

void drawOptions(GLuint prog) {
    glDisable(GL_DEPTH_TEST);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    drawRectNDC(prog, glm::vec3(0,0,0), glm::vec2(2.0f, 2.0f), glm::vec3(0.0f, 0.0f, 0.0f), 0.75f);
    float panelW = 1.4f; float panelH = 1.4f;
    drawRectNDC(prog, glm::vec3(0,0,0), glm::vec2(panelW, panelH), glm::vec3(0.05f, 0.05f, 0.1f), 0.9f);
    
    float uiScale = g_config.uiScale;
    float titleScale = 1.5f * uiScale;
    float textScale  = 1.0f * uiScale;
    float spacing = 0.12f * std::max(0.8f, uiScale); 

    drawRectNDC(prog, glm::vec3(0, 0.6f, 0), glm::vec2(panelW, 0.2f), glm::vec3(0.0f, 0.2f, 0.2f), 1.0f);
    drawTextNDC(prog, "SYSTEM CONFIGURATION", glm::vec3(0, 0.62f, 0), glm::vec3(0.0f, 1.0f, 1.0f), titleScale, ALIGN_CENTER);

    const float startY = 0.35f; 
    
    for (int i = 0; i < NUM_OPTIONS; ++i) {
        float currentY = startY - i * spacing;
        bool isSel = (i == g_selectedOption);
        
        if (isSel) {
            drawRectNDC(prog, glm::vec3(0, currentY, 0), glm::vec2(panelW - 0.1f, 0.08f * uiScale), glm::vec3(0.8f, 0.5f, 0.0f), 0.3f);
            drawTextNDC(prog, ">", glm::vec3(-panelW/2 + 0.1f, currentY, 0), glm::vec3(1.0f, 1.0f, 0.0f), textScale, ALIGN_LEFT);
        }

        glm::vec3 labelCol = isSel ? glm::vec3(1.0f) : glm::vec3(0.7f);
        glm::vec3 valCol   = isSel ? glm::vec3(0.0f, 1.0f, 1.0f) : glm::vec3(0.5f, 0.8f, 0.8f);
        float leftX = -0.5f; float rightX = 0.1f;

        if (i == 0) {
            drawTextNDC(prog, "SCREEN WIDTH", glm::vec3(leftX, currentY, 0), labelCol, textScale, ALIGN_LEFT);
            drawTextNDC(prog, std::to_string(g_config.screenWidth), glm::vec3(rightX, currentY, 0), valCol, textScale, ALIGN_LEFT);
        } else if (i == 1) {
            drawTextNDC(prog, "SCREEN HEIGHT", glm::vec3(leftX, currentY, 0), labelCol, textScale, ALIGN_LEFT);
            drawTextNDC(prog, std::to_string(g_config.screenHeight), glm::vec3(rightX, currentY, 0), valCol, textScale, ALIGN_LEFT);
        } else if (i == 2) {
            drawTextNDC(prog, "SENSITIVITY", glm::vec3(leftX, currentY, 0), labelCol, textScale, ALIGN_LEFT);
            drawProgressBar(prog, rightX + 0.2f, currentY, 0.4f, 0.04f * uiScale, g_config.mouseSensitivity, 1.0f);
        } else if (i == 3) {
            drawTextNDC(prog, "CAMERA SPEED", glm::vec3(leftX, currentY, 0), labelCol, textScale, ALIGN_LEFT);
            drawProgressBar(prog, rightX + 0.2f, currentY, 0.4f, 0.04f * uiScale, g_config.cameraSpeed, 50.0f);
        } else if (i == 4) {
            drawTextNDC(prog, "INVERT Y AXIS", glm::vec3(leftX, currentY, 0), labelCol, textScale, ALIGN_LEFT);
            drawTextNDC(prog, g_config.invertY ? "[ ENABLED ]" : "[ DISABLED ]", glm::vec3(rightX, currentY, 0), valCol, textScale, ALIGN_LEFT);
        } else if (i == 5) { 
            drawTextNDC(prog, "MENU TEXT SIZE", glm::vec3(leftX, currentY, 0), labelCol, textScale, ALIGN_LEFT);
            float uiProgress = (g_config.uiScale - 0.5f); 
            drawProgressBar(prog, rightX + 0.2f, currentY, 0.4f, 0.04f * uiScale, uiProgress, 1.0f);
        } else if (i == 6) {
            drawTextNDC(prog, "[ APPLY & SAVE ]", glm::vec3(0, currentY, 0), isSel ? glm::vec3(0.5f, 1.0f, 0.5f) : glm::vec3(0.3f, 0.7f, 0.3f), textScale * 1.2f, ALIGN_CENTER);
        } else if (i == 7) {
            drawTextNDC(prog, "[ EXIT ]", glm::vec3(0, currentY, 0), isSel ? glm::vec3(1.0f, 0.3f, 0.3f) : glm::vec3(0.7f, 0.3f, 0.3f), textScale * 1.2f, ALIGN_CENTER);
        }
    }
    drawTextNDC(prog, "RESIZE WINDOW TO CHANGE RESOLUTION", glm::vec3(0, -0.6f, 0), glm::vec3(0.5f), 0.8f * uiScale, ALIGN_CENTER);
    glEnable(GL_DEPTH_TEST); glDisable(GL_BLEND);
}

// --- CONSOLE DRAWING ---

void drawConsole(GLuint prog, float time) {
    glDisable(GL_DEPTH_TEST);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    // Drop-down background (Top 50% of screen)
    drawRectNDC(prog, glm::vec3(0, 0.5f, 0), glm::vec2(2.0f, 1.0f), glm::vec3(0.1f, 0.1f, 0.2f), 0.9f);
    
    // Cursor blinking logic
    g_cursorBlink = fmod(time, 1.0f) < 0.5f;

    float startY = 0.9f;
    float lineSpacing = 0.08f;
    float leftX = -0.95f; 
    float textScale = 1.0f;
    int maxLines = 10;
    
    // 1. Draw History
    int historyStart = std::max(0, (int)g_consoleHistory.size() - maxLines);
    
    for (size_t i = historyStart; i < g_consoleHistory.size(); ++i) {
        // Output from execution is green, the prompt is grey
        glm::vec3 color = (g_consoleHistory[i].find("$ ") == 0) ? glm::vec3(0.7f, 0.7f, 0.7f) : glm::vec3(0.0f, 1.0f, 0.0f);
        drawTextNDC(prog, g_consoleHistory[i], glm::vec3(leftX, startY, 0), color, textScale, ALIGN_LEFT);
        startY -= lineSpacing;
    }
    
    // 2. Draw Current Command (White)
    std::string prompt = "$ ";
    std::string cursor = g_cursorBlink ? "_" : " ";
    std::string currentLine = prompt + g_currentCommand + cursor;
    
    drawTextNDC(prog, currentLine, glm::vec3(leftX, startY, 0), glm::vec3(1.0f, 1.0f, 1.0f), textScale, ALIGN_LEFT);

    glEnable(GL_DEPTH_TEST); glDisable(GL_BLEND);
}


int main() {
    loadConfig();
    SDL_Init(SDL_INIT_VIDEO);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3); SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    
    g_window = SDL_CreateWindow("3D System Monitor", 
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, 
        g_config.screenWidth, g_config.screenHeight, 
        SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
        
    SDL_GL_CreateContext(g_window); 
    if (g_appState == STATE_WORLD) SDL_SetRelativeMouseMode(SDL_TRUE);
    else SDL_SetRelativeMouseMode(SDL_FALSE);
    
    // Initialize Console History
    g_consoleHistory.push_back("LX-MONITOR CONSOLE v1.1 - Bash Environment");
    g_consoleHistory.push_back("-----------------------------------------");
    g_consoleHistory.push_back("Press ` (backtick) to open/close.");
    g_consoleHistory.push_back("Try commands like: ls -F, whoami, uptime, ping -c 3 8.8.8.8");
    g_consoleHistory.push_back("");

    glewExperimental=GL_TRUE; glewInit(); glEnable(GL_DEPTH_TEST);
    initFont(); initCubeBuffers(); 

    const char* VS = R"(
    #version 330 core
    layout (location=0) in vec3 aPos; 
    layout (location=1) in vec3 aCol; 
    uniform mat4 model; 
    uniform mat4 view; 
    uniform mat4 projection; 
    uniform bool isHUD;
    void main(){ 
        if(isHUD) gl_Position=vec4(aPos,1.0);
        else gl_Position=projection*view*model*vec4(aPos,1.0); 
    }
    )";
    const char* FS = R"(
    #version 330 core
    uniform vec3 uniColor; 
    uniform float alpha;
    out vec4 Color; 
    void main(){ Color=vec4(uniColor, alpha); }
    )";

    GLuint prog = glCreateProgram();
    auto compile_shader = [](const char* source, GLenum type) -> GLuint {
        GLuint shader = glCreateShader(type); glShaderSource(shader, 1, &source, NULL); glCompileShader(shader);
        int s; char l[512]; glGetShaderiv(shader, GL_COMPILE_STATUS, &s);
        if(!s) { std::cerr << "Shader Err:\n" << l << std::endl; }
        return shader;
    };
    GLuint vs = compile_shader(VS, GL_VERTEX_SHADER); 
    GLuint fs = compile_shader(FS, GL_FRAGMENT_SHADER);
    glAttachShader(prog, vs); glAttachShader(prog, fs); glLinkProgram(prog); 
    glDeleteShader(vs); glDeleteShader(fs);
    
    std::thread t(sysThread); t.detach();
    
    bool run = true; float time = 0;
    while(run) {
        float now = SDL_GetTicks()/1000.0f; g_deltaTime = now - g_lastFrame; g_lastFrame = now; time += g_deltaTime;
        
        SDL_Event e;
        while(SDL_PollEvent(&e)) {
            if(e.type==SDL_QUIT) run=false;
            if (e.type == SDL_WINDOWEVENT && e.window.event == SDL_WINDOWEVENT_RESIZED) {
                int w = e.window.data1; int h = e.window.data2;
                g_config.screenWidth = w; g_config.screenHeight = h; glViewport(0, 0, w, h);
            }
            
            // CONSOLE/OPTIONS TOGGLE
            if(e.type==SDL_KEYDOWN && (e.key.keysym.sym==SDLK_ESCAPE || e.key.keysym.sym==SDLK_F1 || e.key.keysym.sym==SDLK_BACKQUOTE)) {
                if (e.key.keysym.sym == SDLK_BACKQUOTE) {
                    if (g_appState == STATE_WORLD || g_appState == STATE_CONSOLE) {
                        g_appState = (g_appState == STATE_WORLD) ? STATE_CONSOLE : STATE_WORLD;
                    }
                } else { // F1 or ESC
                    if (g_appState == STATE_WORLD || g_appState == STATE_OPTIONS) {
                        g_appState = (g_appState == STATE_WORLD) ? STATE_OPTIONS : STATE_WORLD;
                    } else if (g_appState == STATE_CONSOLE) {
                         g_appState = STATE_WORLD;
                    }
                }
                SDL_SetRelativeMouseMode(g_appState == STATE_WORLD ? SDL_TRUE : SDL_FALSE);
                if (g_appState == STATE_WORLD) SDL_WarpMouseInWindow(g_window, g_config.screenWidth / 2, g_config.screenHeight / 2);
                else if (g_appState == STATE_OPTIONS) g_selectedOption = 0;
            }
            
            if (g_appState == STATE_CONSOLE) {
                if(e.type == SDL_TEXTINPUT) {
                    // Filter out the grave accent key itself if it was the toggle
                    if (e.text.text[0] != '`' && g_currentCommand.length() < 55) {
                        g_currentCommand += e.text.text;
                    }
                } else if (e.type == SDL_KEYDOWN) {
                    if (e.key.keysym.sym == SDLK_RETURN || e.key.keysym.sym == SDLK_KP_ENTER) {
                        if (!g_currentCommand.empty()) {
                            // Clear before executing certain commands
                            if (g_currentCommand == "clear") {
                                g_consoleHistory.clear();
                                g_consoleHistory.push_back("Console Cleared.");
                            } else {
                                // 1. Add command to history
                                g_consoleHistory.push_back("$ " + g_currentCommand);
                                // 2. Execute command
                                std::vector<std::string> output = executeShellCommand(g_currentCommand);
                                // 3. Add output to history
                                g_consoleHistory.insert(g_consoleHistory.end(), output.begin(), output.end());
                            }
                            // 4. Clear current command
                            g_currentCommand.clear();
                            
                            // Keep history manageable (limit to 20 lines)
                            if (g_consoleHistory.size() > 20) {
                                g_consoleHistory.erase(g_consoleHistory.begin(), g_consoleHistory.begin() + (g_consoleHistory.size() - 20));
                            }
                        }
                    } else if (e.key.keysym.sym == SDLK_BACKSPACE && !g_currentCommand.empty()) {
                        g_currentCommand.pop_back();
                    }
                }
            }
            
            if(e.type==SDL_KEYDOWN) {
                if (g_appState == STATE_WORLD) { g_keys[e.key.keysym.scancode] = true; } 
                else if (g_appState == STATE_OPTIONS) { 
                    if (e.key.keysym.sym == SDLK_UP) { g_selectedOption = (g_selectedOption - 1 + NUM_OPTIONS) % NUM_OPTIONS; }
                    else if (e.key.keysym.sym == SDLK_DOWN) { g_selectedOption = (g_selectedOption + 1) % NUM_OPTIONS; }
                    else if (e.key.keysym.sym == SDLK_RETURN) { 
                        if (g_selectedOption == NUM_OPTIONS - 2) { saveConfig(); } 
                        else if (g_selectedOption == NUM_OPTIONS - 1) { run = false; }
                    }
                    float adjust = 0.0f;
                    if (e.key.keysym.sym == SDLK_LEFT) adjust = -1.0f;
                    else if (e.key.keysym.sym == SDLK_RIGHT) adjust = 1.0f;
                    if (adjust != 0.0f && g_selectedOption < 6) {
                        switch (g_selectedOption) {
                            case 0: g_config.screenWidth += (int)(adjust * 100); SDL_SetWindowSize(g_window, g_config.screenWidth, g_config.screenHeight); break;
                            case 1: g_config.screenHeight += (int)(adjust * 100); SDL_SetWindowSize(g_window, g_config.screenWidth, g_config.screenHeight); break;
                            case 2: g_config.mouseSensitivity += adjust * 0.01f; g_config.mouseSensitivity = std::clamp(g_config.mouseSensitivity, 0.01f, 1.0f); g_camera.sensitivity = g_config.mouseSensitivity; break;
                            case 3: g_config.cameraSpeed += adjust * 1.0f; g_config.cameraSpeed = std::clamp(g_config.cameraSpeed, 1.0f, 50.0f); g_camera.speed = g_config.cameraSpeed; break;
                            case 4: g_config.invertY = !g_config.invertY; break;
                            case 5: g_config.uiScale += adjust * 0.05f; g_config.uiScale = std::clamp(g_config.uiScale, 0.5f, 1.5f); break;
                        }
                    }
                }
            }
            if(e.type==SDL_KEYUP) { if (g_appState == STATE_WORLD) g_keys[e.key.keysym.scancode] = false; }
            if(g_appState == STATE_WORLD && e.type==SDL_MOUSEMOTION) {
                float yrel = (g_config.invertY ? -1.0f : 1.0f) * e.motion.yrel;
                g_camera.yaw += e.motion.xrel * g_camera.sensitivity; 
                g_camera.pitch -= yrel * g_camera.sensitivity;
                if(g_camera.pitch > 89) g_camera.pitch = 89; if(g_camera.pitch < -89) g_camera.pitch = -89;
                g_camera.front = glm::normalize(glm::vec3(cos(glm::radians(g_camera.yaw))*cos(glm::radians(g_camera.pitch)), sin(glm::radians(g_camera.pitch)), sin(glm::radians(g_camera.yaw))*cos(glm::radians(g_camera.pitch))));
            }
        }
        
        if (g_appState == STATE_WORLD) processInput();

        glClearColor(0.05f, 0.05f, 0.1f, 1.0f); glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        glUseProgram(prog);
        
        glm::mat4 v = glm::lookAt(g_camera.position, g_camera.position + g_camera.front, g_camera.up);
        glm::mat4 p = glm::perspective(glm::radians(60.0f), (float)g_config.screenWidth / (float)g_config.screenHeight, 0.1f, 200.0f);
        glUniformMatrix4fv(glGetUniformLocation(prog,"view"),1,GL_FALSE,glm::value_ptr(v));
        glUniformMatrix4fv(glGetUniformLocation(prog,"projection"),1,GL_FALSE,glm::value_ptr(p));
        
        drawFloor(prog);
        const float TEXT_Y_POS = 7.0f; const float TEXT_SCALE = 8.0f; 
        
        SystemData currentData; 
        {
            std::lock_guard<std::mutex> lock(g_dataMutex);
            currentData = g_systemData;
        }

        // --- CENTER: HARDWARE TOWERS ---
        drawSystemTower(prog, -10.0f, currentData.cpuUsage, currentData.cpuTemp, glm::vec3(0.0f, 1.0f, 0.0f), time);
        drawTextWorld(prog, "CPU: "+std::to_string((int)currentData.cpuUsage)+"% "+std::to_string((int)currentData.cpuTemp)+"C", glm::vec3(-10.0f, TEXT_Y_POS, 0.0f), glm::vec3(0.0f, 1.0f, 0.0f), TEXT_SCALE, ALIGN_CENTER);
        
        drawSystemTower(prog, -5.0f, currentData.memUsage, 45.0f, glm::vec3(0.0f, 0.5f, 1.0f), time);
        std::stringstream mem_ss; mem_ss << std::fixed << std::setprecision(1) << currentData.memUsed;
        drawTextWorld(prog, "RAM: "+mem_ss.str()+"GB", glm::vec3(-5.0f, TEXT_Y_POS, 0.0f), glm::vec3(0.0f, 0.5f, 1.0f), TEXT_SCALE, ALIGN_CENTER);
        
        drawSystemTower(prog, 0.0f, currentData.gpuUsage, currentData.gpuTemp, glm::vec3(1.0f, 0.0f, 1.0f), time);
        drawTextWorld(prog, "GPU: "+std::to_string((int)currentData.gpuUsage)+"% "+std::to_string((int)currentData.gpuTemp)+"C", glm::vec3(0.0f, TEXT_Y_POS, 0.0f), glm::vec3(1.0f, 0.0f, 1.0f), TEXT_SCALE, ALIGN_CENTER);
        
        drawSystemTower(prog, 5.0f, currentData.netDownloadSpeed / 1024.0f, 40.0f, glm::vec3(0.0f, 1.0f, 1.0f), time);
        std::stringstream net_ss; net_ss << std::fixed << std::setprecision(1) << currentData.netDownloadSpeed;
        drawTextWorld(prog, "NET: "+net_ss.str()+" KB/s", glm::vec3(5.0f, TEXT_Y_POS, 0.0f), glm::vec3(0.0f, 1.0f, 1.0f), TEXT_SCALE, ALIGN_CENTER);
        
        float diskIO = (currentData.diskReadSpeed + currentData.diskWriteSpeed) / 1024.0f;
        drawSystemTower(prog, 10.0f, glm::clamp(diskIO, 0.0f, 100.0f), 35.0f, glm::vec3(1.0f, 1.0f, 0.0f), time);
        std::stringstream disk_ss; disk_ss << std::fixed << std::setprecision(1) << (currentData.diskReadSpeed + currentData.diskWriteSpeed);
        drawTextWorld(prog, "DISK: "+disk_ss.str()+" KB/s", glm::vec3(10.0f, TEXT_Y_POS, 0.0f), glm::vec3(1.0f, 1.0f, 0.0f), TEXT_SCALE, ALIGN_CENTER);

        // --- RIGHT STATION: CONNECTIONS (X = 18.0) ---
        float portBaseX = 18.0f; 
        float portY = 4.0f; // Adjusted position
        drawCube(prog, glm::vec3(portBaseX, 0.5f, 0.0f), glm::vec3(2.5f, 1.0f, 2.0f), glm::vec3(0.1f));
        drawTextWorld(prog, "CONNECTIONS", glm::vec3(portBaseX, portY + 1.5f, 0.0f), glm::vec3(1.0f, 0.8f, 0.2f), 5.0f, ALIGN_CENTER);

        if (currentData.activePorts.empty()) {
             drawTextWorld(prog, "NO TRAFFIC", glm::vec3(portBaseX, portY, 0.0f), glm::vec3(0.4f), 4.0f, ALIGN_CENTER);
             portY -= 0.8f;
        } else {
            for (const auto& pg : currentData.activePorts) {
                std::string label = pg.service;
                if (pg.service == std::to_string(pg.port)) label = "PORT " + std::to_string(pg.port);
                if (pg.count > 1) label += " x" + std::to_string(pg.count);
                glm::vec3 textColor = glm::vec3(0.8f, 0.8f, 1.0f); 
                if (pg.queueSize > 0) { label += " [DATA: " + std::to_string(pg.queueSize) + "]"; textColor = glm::vec3(0.0f, 1.0f, 1.0f); }
                drawTextWorld(prog, label, glm::vec3(portBaseX, portY, 0.0f), textColor, 4.0f, ALIGN_CENTER);
                portY -= 0.8f;
            }
        }

        // --- LEFT STATION: TOP PROCESSES (X = -18.0) ---
        float procBaseX = -18.0f;
        float textStartY = 4.0f; // FIX (v28): Adjusted from 7.0f to 4.0f to be above the platform
        drawCube(prog, glm::vec3(procBaseX, 0.5f, 0.0f), glm::vec3(2.5f, 1.0f, 2.0f), glm::vec3(0.1f));
        drawTextWorld(prog, "TOP TASKS", glm::vec3(procBaseX, textStartY + 1.5f, 0.0f), glm::vec3(1.0f, 0.5f, 0.5f), 5.0f, ALIGN_CENTER);

        float procY = textStartY;
        for (const auto& proc : currentData.topProcesses) {
            std::stringstream ss;
            ss << proc.name << " " << std::fixed << std::setprecision(1) << proc.cpu << "%";
            glm::vec3 color = glm::vec3(0.7f); // Default grey
            if (proc.cpu > 50.0f) color = glm::vec3(1.0f, 0.2f, 0.2f); // High CPU Red
            else if (proc.mem > 10.0f) color = glm::vec3(0.8f, 0.4f, 1.0f); // High Mem Purple
            
            drawTextWorld(prog, ss.str(), glm::vec3(procBaseX, procY, 0.0f), color, 4.0f, ALIGN_CENTER);
            procY -= 0.8f;
        }
        
        // --- HUD ELEMENTS ---
        if (g_appState == STATE_WORLD) {
            drawTextNDC(prog, "[F1] CONFIGURATION  |  [`] CONSOLE", glm::vec3(0.0f, -0.95f, 0), glm::vec3(1.0f, 1.0f, 0.0f), 0.7f, ALIGN_CENTER);
        } else if (g_appState == STATE_OPTIONS) {
            drawOptions(prog);
        } else if (g_appState == STATE_CONSOLE) {
            drawConsole(prog, time);
        }

        SDL_GL_SwapWindow(g_window);
    }
    
    saveConfig();
    glDeleteBuffers(1, &g_cubeVBO); glDeleteBuffers(1, &g_cubeEBO); glDeleteVertexArrays(1, &g_cubeVAO);
    return 0;
}
CPPEOF

print_message "Building Panoramic 3D Monitor (v28 - Fixes applied)..."
cd "$APP_DIR"
mkdir -p build
cd build
cmake ..
make -j$(nproc)

if [ $? -eq 0 ]; then
    print_message "Build completed successfully! 🎉"
else
    print_error "Build failed! Please check the output."
fi

cat > "$APP_DIR/launch.sh" << EOF
#!/bin/bash
CONFIG_FILE="$APP_DIR/config.txt"
if [ ! -f "\$CONFIG_FILE" ]; then
    echo "width=1280" > "\$CONFIG_FILE"
    echo "height=720" >> "\$CONFIG_FILE"
    echo "sensitivity=0.10" >> "\$CONFIG_FILE"
    echo "speed=8.0" >> "\$CONFIG_FILE"
    echo "invertY=false" >> "\$CONFIG_FILE"
    echo "uiScale=1.0" >> "\$CONFIG_FILE"
fi
cd "$APP_DIR/build"
./system_monitor_3d
EOF
chmod +x "$APP_DIR/launch.sh"

print_message ""
print_message "✅ Setup completed!"
print_message "🚀 Launch with: $APP_DIR/launch.sh"
print_message "To use the console, press the backtick key (\`) once the application is running."

#-------------------------------------------------------------------

read -p "🎮 Launch Panoramic 3D Monitor? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_message "🚀 Launching..."
    cd "$APP_DIR/build"
    ./system_monitor_3d
fi
