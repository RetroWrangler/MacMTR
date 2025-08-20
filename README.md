# MacMTR - Network Route Monitor

A native macOS GUI application for MTR (My Traceroute) network monitoring. MacMTR provides a clean, modern interface for visualizing network routes and monitoring packet loss in real-time.

## Features

- **Real-time Network Monitoring**: Continuous monitoring of network routes with live statistics
- **Hostname Resolution**: Automatic reverse DNS lookup for IP addresses along the route
- **Packet Loss Visualization**: Color-coded packet loss percentages with visual indicators
- **Customizable Parameters**: Adjustable hop limits and probe intervals
- **Native macOS Design**: Built with SwiftUI for a modern, responsive interface
- **IPv4 Support**: Focused on reliable IPv4 networking

## Screenshots

MacMTR provides a clean, table-based view of your network route with the following information:

- Hop number and hostname/IP address
- Packet loss percentage with color coding
- Packets sent and received counts
- Latest response time

## Requirements

- macOS 12.4 or later
- Network access permissions
- Administrative privileges for network probing

## Installation

### Building from Source

1. Clone the repository:

   ```bash
   git clone https://github.com/your-username/MacMTR.git
   cd MacMTR
   ```

2. Open the project in Xcode:

   ```bash
   open MacMTR.xcodeproj
   ```

3. Build and run the project in Xcode (⌘+R)

### Pre-built Releases

Download the latest release from the [Releases](https://github.com/your-username/MacMTR/releases) page.

## Usage

1. **Launch MacMTR**
2. **Enter Target Host**: Type a hostname or IP address in the target field
3. **Configure Settings** (optional):
   - Set maximum hops (1-64)
   - Adjust probe interval (0.1-60 seconds)
4. **Start Monitoring**: Click the "Start" button to begin route discovery
5. **Monitor Results**: View real-time statistics in the results table

### Understanding the Results

- **Green/Low Loss**: Normal network performance
- **Yellow/Medium Loss**: Some packet loss detected
- **Orange/High Loss**: Significant packet loss
- **Red/Critical Loss**: Severe packet loss issues

## Technical Details

MacMTR uses the following network tools:

- `traceroute` for route discovery
- TTL-based probing for continuous monitoring
- Native DNS resolution for hostname lookup

The application requires elevated network permissions to send ICMP and UDP packets for network probing.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

### Development Setup

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Inspired by the original MTR (My Traceroute) command-line tool
- Built with SwiftUI and modern macOS development practices
- Thanks to the network monitoring community for tools and techniques

## Support

If you encounter any issues or have questions:

- Open an issue on GitHub
- Check existing issues for solutions
- Refer to the macOS Console for detailed error messages

---

**Note**: MacMTR requires network permissions and may prompt for authorization on first launch. This is normal and necessary for network monitoring functionality.
