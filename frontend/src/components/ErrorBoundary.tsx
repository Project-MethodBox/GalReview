import { Component, type ErrorInfo, type ReactNode } from 'react'

interface Props {
  children: ReactNode
}

interface State {
  hasError: boolean
  message: string
}

/**
 * 全局错误边界：捕获子树渲染期间的未处理异常，防止白屏崩溃。
 * 用户可点击"刷新页面"恢复。
 */
export default class ErrorBoundary extends Component<Props, State> {
  constructor(props: Props) {
    super(props)
    this.state = { hasError: false, message: '' }
  }

  static getDerivedStateFromError(error: Error): State {
    return { hasError: true, message: error.message || '未知错误' }
  }

  componentDidCatch(error: Error, info: ErrorInfo): void {
    console.error('ErrorBoundary caught an error:', error, info.componentStack)
  }

  render(): ReactNode {
    if (this.state.hasError) {
      return (
        <main className="error-boundary" role="alert">
          <div className="error-boundary__card">
            <h1>页面出了点问题</h1>
            <p>应用遇到了一个意外错误。刷新页面通常可以恢复正常。</p>
            <pre className="error-boundary__detail">{this.state.message}</pre>
            <button
              className="button button--primary"
              type="button"
              onClick={() => window.location.reload()}
            >
              刷新页面
            </button>
          </div>
        </main>
      )
    }
    return this.props.children
  }
}
