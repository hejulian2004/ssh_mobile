#include "windows_video_processor.h"

namespace realtime_media_windows {

bool Nv12ToBgraConverter::Initialize(ID3D11Device* device,
                                     ID3D11DeviceContext* context) {
  if (device == nullptr || context == nullptr ||
      FAILED(device->QueryInterface(IID_PPV_ARGS(device_.put()))) ||
      FAILED(context->QueryInterface(IID_PPV_ARGS(context_.put()))) ||
      FAILED(device->QueryInterface(IID_PPV_ARGS(video_device_.put()))) ||
      FAILED(context->QueryInterface(IID_PPV_ARGS(video_context_.put())))) {
    return false;
  }
  return true;
}

bool Nv12ToBgraConverter::Configure(uint32_t width, uint32_t height) {
  if (width == 0 || height == 0 || video_device_ == nullptr) return false;
  if (processor_ != nullptr && width_ == width && height_ == height) {
    return true;
  }

  D3D11_VIDEO_PROCESSOR_CONTENT_DESC content = {};
  content.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
  content.InputFrameRate.Numerator = 30;
  content.InputFrameRate.Denominator = 1;
  content.InputWidth = width;
  content.InputHeight = height;
  content.OutputFrameRate.Numerator = 30;
  content.OutputFrameRate.Denominator = 1;
  content.OutputWidth = width;
  content.OutputHeight = height;

  winrt::com_ptr<ID3D11VideoProcessorEnumerator> enumerator;
  if (FAILED(video_device_->CreateVideoProcessorEnumerator(
          &content, enumerator.put()))) {
    return false;
  }
  winrt::com_ptr<ID3D11VideoProcessor> processor;
  if (FAILED(video_device_->CreateVideoProcessor(enumerator.get(), 0,
                                                 processor.put()))) {
    return false;
  }
  enumerator_ = std::move(enumerator);
  processor_ = std::move(processor);
  width_ = width;
  height_ = height;
  return true;
}

bool Nv12ToBgraConverter::Convert(
    ID3D11Texture2D* input,
    winrt::com_ptr<ID3D11Texture2D>* output) {
  if (input == nullptr || output == nullptr || enumerator_ == nullptr ||
      processor_ == nullptr || video_context_ == nullptr) {
    return false;
  }

  D3D11_TEXTURE2D_DESC output_description = {};
  output_description.Width = width_;
  output_description.Height = height_;
  output_description.MipLevels = 1;
  output_description.ArraySize = 1;
  output_description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  output_description.SampleDesc.Count = 1;
  output_description.Usage = D3D11_USAGE_DEFAULT;
  output_description.BindFlags = D3D11_BIND_RENDER_TARGET;
  winrt::com_ptr<ID3D11Texture2D> output_texture;
  if (FAILED(device_->CreateTexture2D(&output_description, nullptr,
                                      output_texture.put()))) {
    return false;
  }

  D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC input_description = {};
  input_description.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
  input_description.Texture2D.MipSlice = 0;
  input_description.Texture2D.ArraySlice = 0;
  winrt::com_ptr<ID3D11VideoProcessorInputView> input_view;
  if (FAILED(video_device_->CreateVideoProcessorInputView(
          input, enumerator_.get(), &input_description, input_view.put()))) {
    return false;
  }

  D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC output_view_description = {};
  output_view_description.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
  output_view_description.Texture2D.MipSlice = 0;
  winrt::com_ptr<ID3D11VideoProcessorOutputView> output_view;
  if (FAILED(video_device_->CreateVideoProcessorOutputView(
          output_texture.get(), enumerator_.get(), &output_view_description,
          output_view.put()))) {
    return false;
  }

  D3D11_VIDEO_PROCESSOR_STREAM stream = {};
  stream.Enable = TRUE;
  stream.pInputSurface = input_view.get();
  video_context_->VideoProcessorSetStreamFrameFormat(
      processor_.get(), 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
  if (FAILED(video_context_->VideoProcessorBlt(processor_.get(),
                                               output_view.get(), 0, 1,
                                               &stream))) {
    return false;
  }
  *output = std::move(output_texture);
  return true;
}

}  // namespace realtime_media_windows
