import type { Metadata } from "next";
import "./globals.css";
import { ClientBody } from "./ClientBody";
import { Navbar } from "@/components/layout/Navbar";
import { Footer } from "@/components/layout/Footer";
import { ThemeProvider } from "@/components/ThemeProvider";

export const metadata: Metadata = {
  title: "Blockchain Attack Detection - Analyze and Evaluate Transactions",
  description: "A cutting-edge tool to identify blockchain transaction attacks. Input transaction hashes to receive model responses, recall rates, and comprehensive evaluation metrics.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body className="min-h-screen bg-background dark:bg-dark-background">
        <ThemeProvider
          attribute="class"
          defaultTheme="dark"
          enableSystem={true}
        >
          <ClientBody>
            {/* 固定导航栏 */}
            <div className="fixed top-0 w-full z-50">
              <Navbar />
            </div>
            
            {/* 主内容区 - 16:9比例容器 */}
            <div className="w-full aspect-[16/8] bg-background dark:bg-dark-background rounded-lg shadow-xl overflow-hidden border border-border dark:border-dark-border">
              {children}
            </div>

            {/* 页脚 */}
            <Footer />
          </ClientBody>
        </ThemeProvider>
      </body>
    </html>
  );
}