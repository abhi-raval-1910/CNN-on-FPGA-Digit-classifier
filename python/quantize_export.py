"""
Loads fpga_cnn_weights.pth, quantizes every layer to signed INT8
(symmetric, per-tensor), reports the accuracy after quantization, and
writes conv1_weights.mem / fc_weights.mem as plain hex text files that
the Verilog weight_rom module loads with $readmemh.

Address layout matches the RTL exactly:
  conv1_weights.mem : 36 lines  -> addr = f*9 + ky*3 + kx      (f=0..3, ky/kx=0..2)
  fc_weights.mem     : 6760 lines -> addr = out*676 + in        (out=0..9, in=0..675)

These match PyTorch's default flatten order (out_channels-major), so no
reordering is needed beyond a straight .flatten().

Run: python quantize_export.py
"""
import torch
from train_model import FPGACNN
from torchvision import datasets, transforms
from torch.utils.data import DataLoader


def quantize_symmetric(tensor):
    max_val = torch.max(torch.abs(tensor))
    scale = 127.0 / (max_val + 1e-7)
    q = torch.round(tensor * scale)
    q = torch.clamp(q, -128, 127)
    return q.to(torch.int8), scale.item()


def write_mem_file(int8_tensor, filename):
    vals = int8_tensor.flatten().tolist()
    with open(filename, "w") as f:
        for v in vals:
            f.write(f"{(v & 0xFF):02X}\n")
    print(f"Wrote {len(vals)} values to {filename}")


def evaluate(model, loader):
    model.eval()
    correct, total = 0, 0
    with torch.no_grad():
        for images, labels in loader:
            outputs = model(images)
            _, predicted = torch.max(outputs.data, 1)
            total += labels.size(0)
            correct += (predicted == labels).sum().item()
    return 100 * correct / total


def main():
    model = FPGACNN()
    model.load_state_dict(torch.load("fpga_cnn_weights.pth"))
    model.eval()

    conv1_q, conv1_scale = quantize_symmetric(model.conv1.weight.data)
    fc_q, fc_scale = quantize_symmetric(model.fc.weight.data)

    print(f"conv1 scale: {conv1_scale:.4f}  shape: {tuple(conv1_q.shape)}  numel: {conv1_q.numel()}")
    print(f"fc scale:    {fc_scale:.4f}  shape: {tuple(fc_q.shape)}  numel: {fc_q.numel()}")

    write_mem_file(conv1_q, "conv1_weights.mem")
    write_mem_file(fc_q, "fc_weights.mem")

    # Sanity-check accuracy drop from quantization (weights only, fake-quant forward pass)
    transform = transforms.Compose([transforms.ToTensor()])
    test_dataset = datasets.MNIST(root="./data", train=False, download=True, transform=transform)
    test_loader = DataLoader(test_dataset, batch_size=256, shuffle=False)

    print(f"Float32 baseline accuracy: {evaluate(model, test_loader):.2f}%")

    with torch.no_grad():
        model.conv1.weight.data = conv1_q.float() / conv1_scale
        model.fc.weight.data = fc_q.float() / fc_scale
    print(f"Simulated INT8-weight accuracy: {evaluate(model, test_loader):.2f}%")

    print("\nIMPORTANT: copy conv1_weights.mem and fc_weights.mem into your")
    print("Vivado project directory (same folder Vivado runs synthesis from),")
    print("or add them as 'Simulation/Synthesis Sources' so $readmemh can find them.")


if __name__ == "__main__":
    main()
