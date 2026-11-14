#ifndef RUNNER_DIRECT_FABRIC_PLUGIN_H_
#define RUNNER_DIRECT_FABRIC_PLUGIN_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

#include <memory>

constexpr UINT WM_DAPHQ_DIRECT_TASK = WM_APP + 402;

class DirectFabricPlugin {
 public:
  explicit DirectFabricPlugin(flutter::BinaryMessenger* messenger, HWND hwnd);
  ~DirectFabricPlugin();

  DirectFabricPlugin(const DirectFabricPlugin&) = delete;
  DirectFabricPlugin& operator=(const DirectFabricPlugin&) = delete;

  void DrainPendingTasks();
  void Shutdown();

 private:
  struct Impl;
  std::shared_ptr<Impl> impl_;
};

#endif  // RUNNER_DIRECT_FABRIC_PLUGIN_H_
