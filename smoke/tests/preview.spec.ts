import { expect, test } from "@playwright/test"

const USER = process.env.PREVIEW_USER ?? "admin@yutianran.cn"
const PASSWORD = process.env.PREVIEW_PASSWORD ?? ""

test("API health check responds", async ({ request }) => {
  const res = await request.get("/api/v1/utils/health-check/")
  expect(res.ok()).toBeTruthy()
  expect((await res.text()).trim()).toBe("true")
})

test("OpenAPI docs and schema load", async ({ page, request }) => {
  await page.goto("/docs")
  await expect(page.locator("body")).toContainText(/OAS\s*3\./i)

  const res = await request.get("/api/v1/openapi.json")
  expect(res.ok()).toBeTruthy()
  const spec = await res.json()
  expect(spec.openapi).toBeTruthy()
  expect(spec.paths["/api/v1/items/"]).toBeTruthy()
  expect(spec.paths["/api/v1/utils/health-check/"]).toBeTruthy()
})

test("frontend serves the app", async ({ page }) => {
  await page.goto("/")
  await expect(page.locator("body")).toContainText(/login|items|fastapi/i)
})

test("seeded superuser can log in and sees seed items", async ({ page }) => {
  test.skip(!PASSWORD, "PREVIEW_PASSWORD is not set")

  await page.goto("/login")
  await page.getByLabel(/email/i).fill(USER)
  await page.locator('input[type="password"]').fill(PASSWORD)
  await page.getByRole("button", { name: /log ?in/i }).click()

  await expect(page).not.toHaveURL(/\/login/, { timeout: 20_000 })
  await page.goto("/items")
  await expect(page.getByRole("heading", { name: /^items$/i })).toBeVisible()
  await expect(page.locator("body")).toContainText("演示任务", {
    timeout: 30_000,
  })
})
