from app.repositories.base import BaseRepository, Row


class ProductImageRepository(BaseRepository):
    table = "product_images"

    def __init__(self, client):
        super().__init__(client)

    def for_products(self, product_ids: list[str]) -> list[Row]:
        if not product_ids:
            return []
        q = self.client.table(self.table).select("*").in_("product_id", product_ids).order("sort_order").order("created_at")
        return self._run(q).data

    def for_product(self, product_id: str) -> list[Row]:
        return self.for_products([product_id])

    def find(self, product_id: str, image_id: str) -> Row | None:
        res = self._run(self.client.table(self.table).select("*").eq("id", image_id).eq("product_id", product_id).limit(1))
        return res.data[0] if res.data else None

    def add(self, values: Row) -> Row:
        return self.create(values)

    def modify(self, image_id: str, values: Row) -> Row:
        return self.update(image_id, values)

    def remove(self, image_id: str) -> None:
        self.delete(image_id)

    def clear_primary(self, product_id: str) -> None:
        self._run(self.client.table(self.table).update({"is_primary": False}).eq("product_id", product_id).eq("is_primary", True))
