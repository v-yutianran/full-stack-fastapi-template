"""Idempotent demo seed data shared by staging and PR preview environments.

Run from the backend container (working directory /app/backend):
    SEED_DEMO_DATA=true python scripts/seed_demo.py
or through scripts/post_start.sh.

The data is deterministic: running it repeatedly only inserts missing items,
so staging and preview environments end up with the same seed data set.
"""

import os
import sys

# Make ``app`` importable when the script is executed by path.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlmodel import Session, select  # noqa: E402

from app.core.config import settings  # noqa: E402
from app.core.db import engine  # noqa: E402
from app.models import Item, User  # noqa: E402

DEMO_ITEMS: list[tuple[str, str]] = [
    ("演示任务：整理产品需求", "来自 staging 种子数据的示例任务，可用于验证列表与详情。"),
    ("演示任务：检查接口文档", "打开 /docs 确认 OpenAPI 文档可访问。"),
    ("演示任务：验证登录流程", "使用 FIRST_SUPERUSER 账号登录并查看 Items 页面。"),
    ("演示任务：检查分页与搜索", "确认种子数据在表格中正常展示。"),
    ("演示任务：准备验收清单", "预览环境验收前逐项核对。"),
]


def main() -> None:
    with Session(engine) as session:
        user = session.exec(
            select(User).where(User.email == settings.FIRST_SUPERUSER)
        ).first()
        if user is None:
            print("superuser not found, skipping demo seed")
            return

        existing_titles = set(session.exec(select(Item.title)).all())
        created = 0
        for title, description in DEMO_ITEMS:
            if title in existing_titles:
                continue
            session.add(Item(title=title, description=description, owner_id=user.id))
            created += 1

        session.commit()
        total = session.exec(select(Item)).all()
        print(f"demo seed complete: created {created} item(s), total {len(total)}")


if __name__ == "__main__":
    main()
