// ONNX Runtime smoke test: loads smoke.onnx (y = 2x + 1 on float32[4])
// through the C++ API on one thread, runs it once, and checks the result.
//
// Exit status: 0 on success, 1 on a wrong result, 2 if ONNX Runtime fails.
// The test proves the target library loads and runs inference; ONNX is a
// noncritical analytics component and is deliberately not part of the A/B
// update health check.

#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>

#include <onnxruntime_cxx_api.h>

int main(int argc, char** argv) {
  char const* model = argc > 1 ? argv[1] : "/usr/share/hft/onnx/smoke.onnx";
  try {
    Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "hft-onnx-smoke"};
    Ort::SessionOptions options;
    options.SetIntraOpNumThreads(1);
    options.SetInterOpNumThreads(1);
    Ort::Session session{env, model, options};

    std::array<float, 4> input{-1.0F, 0.0F, 0.5F, 3.0F};
    std::array<std::int64_t, 1> shape{4};
    auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    auto tensor = Ort::Value::CreateTensor<float>(memory, input.data(), input.size(),
                                                  shape.data(), shape.size());
    std::array<char const*, 1> inputs{"x"};
    std::array<char const*, 1> outputs{"y"};
    auto results = session.Run(Ort::RunOptions{nullptr}, inputs.data(), &tensor, 1,
                               outputs.data(), 1);
    float const* y = results.front().GetTensorData<float>();

    for (std::size_t index = 0; index < input.size(); ++index) {
      float const expected = (2.0F * input[index]) + 1.0F;
      if (std::fabs(y[index] - expected) > 1e-6F) {
        std::fprintf(stderr, "hft-onnx-smoke: y[%zu] = %f, expected %f\n", index,
                     static_cast<double>(y[index]), static_cast<double>(expected));
        return 1;
      }
    }
    std::printf("hft-onnx-smoke: ok (ONNX Runtime %s)\n", Ort::GetVersionString().c_str());
    return 0;
  } catch (Ort::Exception const& error) {
    std::fprintf(stderr, "hft-onnx-smoke: %s\n", error.what());
    return 2;
  }
}
