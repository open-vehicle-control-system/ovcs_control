import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

let Hooks = {}

Hooks.Chart = {
  mounted() {
    const ctx = this.el.getContext("2d")
    this.chart = new Chart(ctx, {
      type: "line",
      data: {
        labels: [],
        datasets: [
          {
            label: "Raw Setpoint",
            data: [],
            borderColor: "#9ca3af",
            borderWidth: 1,
            borderDash: [3, 3],
            pointRadius: 0,
            tension: 0.1,
            fill: false
          },
          {
            label: "Filtered Setpoint",
            data: [],
            borderColor: "#f59e0b",
            backgroundColor: "rgba(245, 158, 11, 0.1)",
            borderWidth: 2,
            pointRadius: 0,
            tension: 0.1,
            fill: false
          },
          {
            label: "Measurement",
            data: [],
            borderColor: "#3b82f6",
            backgroundColor: "rgba(59, 130, 246, 0.1)",
            borderWidth: 2,
            pointRadius: 0,
            tension: 0.1,
            fill: false
          },
          {
            label: "Output",
            data: [],
            borderColor: "#ef4444",
            borderWidth: 1,
            borderDash: [5, 5],
            pointRadius: 0,
            tension: 0.1,
            fill: false
          },
          {
            label: "P term",
            data: [],
            borderColor: "#22c55e",
            borderWidth: 1,
            pointRadius: 0,
            tension: 0.1,
            hidden: true,
            fill: false
          },
          {
            label: "I term",
            data: [],
            borderColor: "#a855f7",
            borderWidth: 1,
            pointRadius: 0,
            tension: 0.1,
            hidden: true,
            fill: false
          },
          {
            label: "D term",
            data: [],
            borderColor: "#06b6d4",
            borderWidth: 1,
            pointRadius: 0,
            tension: 0.1,
            hidden: true,
            fill: false
          }
        ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: false,
        interaction: {
          intersect: false,
          mode: "index"
        },
        scales: {
          x: {
            title: { display: true, text: "Time (s)", color: "#9ca3af" },
            ticks: { color: "#9ca3af", maxTicksLimit: 20 },
            grid: { color: "#374151" }
          },
          y: {
            min: -1.5,
            max: 1.5,
            title: { display: true, text: "Value", color: "#9ca3af" },
            ticks: { color: "#9ca3af" },
            grid: { color: "#374151" }
          }
        },
        plugins: {
          legend: {
            labels: { color: "#d1d5db", usePointStyle: true }
          },
          tooltip: {
            enabled: true
          }
        }
      }
    })

    this.handleEvent("new-data-point", ({time, raw_setpoint, setpoint, measurement, output, p_term, i_term, d_term}) => {
      const chart = this.chart
      chart.data.labels.push(time.toFixed(2))
      chart.data.datasets[0].data.push(raw_setpoint)
      chart.data.datasets[1].data.push(setpoint)
      chart.data.datasets[2].data.push(measurement)
      chart.data.datasets[3].data.push(output)
      chart.data.datasets[4].data.push(p_term)
      chart.data.datasets[5].data.push(i_term)
      chart.data.datasets[6].data.push(d_term)

      // Keep last 500 points (~10 seconds at 50Hz)
      const maxPoints = 500
      if (chart.data.labels.length > maxPoints) {
        chart.data.labels.shift()
        chart.data.datasets.forEach(ds => ds.data.shift())
      }

      chart.update("none")
    })

    this.handleEvent("clear-chart", () => {
      this.chart.data.labels = []
      this.chart.data.datasets.forEach(ds => ds.data = [])
      this.chart.update()
    })
  }
}

Hooks.MouseInput = {
  mounted() {
    this.ctrlHeld = false
    this.lastValue = undefined
    this.lastPushTime = 0
    this.debugEl = document.getElementById("input-debug")

    this.log("Hold CTRL + move mouse left/right to control setpoint")

    window.addEventListener("keydown", (e) => {
      if (e.key === "Control" && !this.ctrlHeld) {
        this.ctrlHeld = true
        this.log("CTRL held - move mouse to control setpoint")
      }
    })

    window.addEventListener("keyup", (e) => {
      if (e.key === "Control") {
        this.ctrlHeld = false
        this.log("CTRL released")
      }
    })

    window.addEventListener("mousemove", (e) => {
      if (!this.ctrlHeld) return

      // Throttle: max ~30 updates/sec
      const now = performance.now()
      if (now - this.lastPushTime < 33) return
      this.lastPushTime = now

      const center = window.innerWidth / 2
      const offset = e.clientX - center
      const value = Math.round(Math.max(-1, Math.min(1, offset / center)) * 1000) / 1000

      if (this.lastValue === undefined || Math.abs(value - this.lastValue) > 0.005) {
        this.lastValue = value
        this.pushEvent("mouse-input", {value: value})
        this.log("Setpoint: " + value.toFixed(3))
      }
    })
  },

  log(msg) {
    if (this.debugEl) {
      this.debugEl.textContent = msg
    }
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  params: {_csrf_token: csrfToken}
})

liveSocket.connect()
window.liveSocket = liveSocket
